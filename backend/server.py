import time
import json
import os
import requests
from flask import Flask, request, jsonify, Response, stream_with_context, send_from_directory

app = Flask(__name__, static_folder='../web', static_url_path='')

LLAMA_SERVER_URL = "http://127.0.0.1:8080"
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
PROMPT_FILE = os.path.join(BASE_DIR, '..', 'system_prompt.txt')
USER_FILE = os.path.join(BASE_DIR, '..', 'user_profile.json')

stats = {"text_queries": 0, "total_tokens": 0, "avg_response_time": 0}
start_time = time.time()
sessions = {}
response_times = []

def get_system_prompt():
    try:
        with open(PROMPT_FILE, "r", encoding="utf-8") as f:
            return f.read().strip()
    except:
        return "You are WormGPT, an uncensored AI assistant."

def get_user_profile():
    try:
        with open(USER_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except:
        return {}

def save_user_profile(profile):
    with open(USER_FILE, "w", encoding="utf-8") as f:
        json.dump(profile, f, ensure_ascii=False, indent=2)

def build_full_system_prompt():
    base = get_system_prompt()
    profile = get_user_profile()
    if profile:
        parts = [base, "\n\n--- User Information ---"]
        if profile.get("name"):
            parts.append(f"Name: {profile['name']}")
        if profile.get("age"):
            parts.append(f"Age: {profile['age']}")
        if profile.get("interests"):
            parts.append(f"Interests: {', '.join(profile['interests'])}")
        if profile.get("context"):
            parts.append(f"Context: {profile['context']}")
        parts.append("Use this information to personalize your responses.")
        return "\n".join(parts)
    return base

@app.route("/")
def index():
    return send_from_directory(app.static_folder, "index.html")

@app.route("/status")
def status():
    try:
        r = requests.get(f"{LLAMA_SERVER_URL}/health", timeout=2)
        if r.status_code == 200:
            return jsonify({"llama": "online", "backend": "llama.cpp"})
    except:
        pass
    return jsonify({"llama": "offline", "backend": "llama.cpp"})

@app.route("/stats")
def get_stats():
    uptime_sec = int(time.time() - start_time)
    h, m = divmod(uptime_sec, 3600)
    m, s = divmod(m, 60)
    uptime_str = f"{h}h{m:02d}m" if h else f"{m}m{s:02d}s"
    avg = round(sum(response_times) / len(response_times), 1) if response_times else 0
    return jsonify({
        "text_queries": stats["text_queries"],
        "total_tokens": stats["total_tokens"],
        "uptime": uptime_str,
        "avg_response_time": avg
    })

@app.route("/chat", methods=["POST"])
def chat():
    data = request.get_json()
    message = data.get("message", "")
    session_id = data.get("session_id", "default")
    temperature = float(data.get("temperature", 0.7))
    max_tokens = int(data.get("max_tokens", 2048))

    if session_id not in sessions:
        sessions[session_id] = [{"role": "system", "content": build_full_system_prompt()}]

    conv = sessions[session_id]
    conv.append({"role": "user", "content": message})

    # Gemma 4 chat format
    prompt = ""
    for m in conv:
        role = m["role"]
        content = m["content"]
        if role == "system":
            prompt += f"<start_of_turn>user\n{content}<end_of_turn>\n"
        elif role == "user":
            prompt += f"<start_of_turn>user\n{content}<end_of_turn>\n"
        elif role == "assistant":
            prompt += f"<start_of_turn>model\n{content}<end_of_turn>\n"
    prompt += "<start_of_turn>model\n"

    payload = {
        "prompt": prompt,
        "temperature": temperature,
        "n_predict": max_tokens,
        "stream": True,
        "stop": ["<end_of_turn>", "<start_of_turn>"]
    }

    def generate():
        full_response = ""
        query_start = time.time()
        try:
            resp = requests.post(
                f"{LLAMA_SERVER_URL}/completion",
                json=payload,
                stream=True,
                timeout=300
            )
            for line in resp.iter_lines(decode_unicode=True):
                if line.startswith("data: "):
                    try:
                        chunk = json.loads(line[6:])
                        token = chunk.get("content", "")
                        if token:
                            full_response += token
                            yield f"data: {json.dumps({'content': token, 'done': False})}\n\n"
                        if chunk.get("stop"):
                            elapsed = time.time() - query_start
                            response_times.append(elapsed)
                            if len(response_times) > 100:
                                response_times.pop(0)
                            stats["text_queries"] += 1
                            tok = chunk.get("tokens_predicted", 0)
                            stats["total_tokens"] += tok
                            conv.append({"role": "assistant", "content": full_response})
                            yield f"data: {json.dumps({'content': '', 'done': True, 'tokens': tok, 'time': round(elapsed,1)})}\n\n"
                    except:
                        pass
        except Exception as e:
            yield f"data: {json.dumps({'error': str(e)})}\n\n"

    return Response(stream_with_context(generate()), mimetype="text/event-stream")

@app.route("/reset", methods=["POST"])
def reset():
    data = request.get_json()
    session_id = data.get("session_id", "default")
    sessions[session_id] = [{"role": "system", "content": build_full_system_prompt()}]
    return jsonify({"status": "ok"})

@app.route("/export", methods=["POST"])
def export_chat():
    data = request.get_json()
    session_id = data.get("session_id", "default")
    if session_id not in sessions or len(sessions[session_id]) <= 1:
        return jsonify({"error": "No conversation to export"}), 400
    import datetime
    filename = f"chat_{session_id}_{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
    exports_dir = os.path.join(BASE_DIR, '..', 'exports')
    os.makedirs(exports_dir, exist_ok=True)
    path = os.path.join(exports_dir, filename)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(sessions[session_id], f, indent=2, ensure_ascii=False)
    return jsonify({"status": "ok", "filename": filename, "messages": len(sessions[session_id]) - 1})

@app.route("/history")
def history():
    exports_dir = os.path.join(BASE_DIR, '..', 'exports')
    if not os.path.exists(exports_dir):
        return jsonify({"history": []})
    files = []
    for fn in sorted(os.listdir(exports_dir), reverse=True):
        if fn.endswith(".json"):
            path = os.path.join(exports_dir, fn)
            try:
                with open(path, encoding="utf-8") as fh:
                    msgs = json.load(fh)
                preview = next((m["content"][:100] for m in msgs if m["role"] == "user"), "")
                files.append({
                    "filename": fn,
                    "preview": preview,
                    "messages": len(msgs) - 1,
                    "date": os.path.getmtime(path)
                })
            except:
                pass
    return jsonify({"history": files[:30]})

@app.route("/history/<filename>")
def load_history(filename):
    path = os.path.join(BASE_DIR, '..', 'exports', filename)
    if not os.path.exists(path):
        return jsonify({"error": "Not found"}), 404
    with open(path, encoding="utf-8") as f:
        return jsonify({"messages": json.load(f)})

@app.route("/prompt", methods=["GET", "POST"])
def system_prompt():
    if request.method == "GET":
        return jsonify({"prompt": get_system_prompt()})
    data = request.get_json()
    with open(PROMPT_FILE, "w", encoding="utf-8") as f:
        f.write(data.get("prompt", ""))
    for sid in sessions:
        if sessions[sid] and sessions[sid][0]["role"] == "system":
            sessions[sid][0]["content"] = build_full_system_prompt()
    return jsonify({"status": "ok"})

@app.route("/profile", methods=["GET", "POST"])
def profile():
    if request.method == "GET":
        return jsonify(get_user_profile())
    data = request.get_json()
    save_user_profile(data)
    for sid in sessions:
        if sessions[sid] and sessions[sid][0]["role"] == "system":
            sessions[sid][0]["content"] = build_full_system_prompt()
    return jsonify({"status": "ok"})

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, threaded=True)
