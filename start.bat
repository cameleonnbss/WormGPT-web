@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"
title WormGPT Launcher

echo =====================================
echo   W O R M G P T   L A U N C H E R
echo =====================================
echo.

:: ---------- READ CONFIG ----------
set CTX=2048
if exist "deps\ctx.txt" set /p CTX=<deps\ctx.txt

:: ---------- FIND MODEL ----------
set MODEL=
for %%f in (models\*.gguf) do (
    if "!MODEL!"=="" set MODEL=%%f
)
if "%MODEL%"=="" (
    echo [FATAL] No .gguf model found in models\
    echo Run install.bat first.
    pause & exit /b 1
)
echo [OK] Model: %MODEL%

:: ---------- CHECK SERVER ----------
if not exist "deps\llama-server.exe" (
    echo [FATAL] deps\llama-server.exe not found.
    echo Run install.bat first.
    pause & exit /b 1
)

:: ---------- FREE PORTS ----------
for /f "tokens=5" %%a in ('netstat -aon ^| find ":8080" ^| find "LISTENING" 2^>nul') do (
    echo [INFO] Freeing port 8080 (PID %%a)
    taskkill /F /PID %%a 2>nul
)
for /f "tokens=5" %%a in ('netstat -aon ^| find ":5000" ^| find "LISTENING" 2^>nul') do (
    echo [INFO] Freeing port 5000 (PID %%a)
    taskkill /F /PID %%a 2>nul
)

:: ---------- ENSURE PYTHON DEPS ----------
python -m pip install flask flask-cors requests --quiet --user 2>nul

:: ---------- START LLAMA SERVER ----------
echo [INFO] Starting llama.cpp server (context: %CTX% tokens)...
set ROOT=%~dp0
start "llama-server" /D "%ROOT%deps" "llama-server.exe" -m "%ROOT%%MODEL%" --host 127.0.0.1 --port 8080 -c %CTX%

:: ---------- WAIT FOR SERVER ----------
echo Waiting for llama-server to become ready...
set COUNT=0
:waitloop
timeout /t 1 /nobreak >nul
curl -s http://127.0.0.1:8080/health >nul 2>&1
if %errorlevel% equ 0 goto :server_ok
set /a COUNT+=1
if %COUNT% leq 60 goto :waitloop
echo [FATAL] Server did not start within 60 seconds.
echo Check the llama-server window for errors.
pause & exit /b 1

:server_ok
echo [OK] llama-server is running on http://127.0.0.1:8080
echo.

:: ---------- START BACKEND ----------
echo [INFO] Starting WormGPT web backend...
start http://localhost:5000
cd backend
python server.py
if %errorlevel% neq 0 (
    echo [FATAL] Python backend crashed! See error above.
    pause
)
