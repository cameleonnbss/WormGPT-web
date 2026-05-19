@echo off
setlocal enabledelayedexpansion
title WormGPT Installer

echo ============================================
echo   W O R M G P T   I N S T A L L E R
echo ============================================
echo.

:: ---------- CHECK PYTHON & GIT ----------
where python >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Python not found. Install Python 3.10+ from https://python.org
    pause
    exit /b 1
)
where git >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] Git not found. Install from https://git-scm.com
    pause
    exit /b 1
)

:: ---------- VRAM DETECTION ----------
set VRAM=0
where nvidia-smi >nul 2>&1
if %errorlevel% equ 0 (
    for /f "skip=1 tokens=1" %%i in ('nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2^>nul') do (
        if "!VRAM!"=="0" set VRAM=%%i
    )
)

if "%VRAM%"=="0" (
    echo [WARNING] VRAM not auto-detected.
    set /p VRAM="Enter your GPU VRAM in MB (e.g., 4096 for 4GB, 8192 for 8GB): "
)
echo [INFO] VRAM: %VRAM% MB

:: ---------- CHOOSE QUANTIZATION ----------
if %VRAM% lss 8192 (
    set QUANT=Q4_K_M
    set CTX=2048
) else if %VRAM% lss 12288 (
    set QUANT=Q5_K_M
    set CTX=4096
) else if %VRAM% lss 16384 (
    set QUANT=Q6_K
    set CTX=4096
) else (
    set QUANT=Q8_0
    set CTX=8192
)
echo [INFO] Selected quantization: %QUANT% (context: %CTX% tokens)

:: ---------- CREATE FOLDERS ----------
if not exist "models"  mkdir models
if not exist "deps"    mkdir deps
if not exist "backend" mkdir backend

:: ---------- DOWNLOAD LLAMA.CPP SERVER ----------
if not exist "deps\llama-server.exe" (
    echo [INFO] Downloading pre-built llama.cpp server...
    set LLAMA_URL=https://github.com/ggml-org/llama.cpp/releases/download/b9222/llama-b9222-bin-win-avx2-x64.zip
    set LLAMA_ZIP=deps\llama-server.zip
    set LLAMA_TMP=deps\llama-extract

    curl -L --retry 3 -o "!LLAMA_ZIP!" "!LLAMA_URL!"
    if not exist "!LLAMA_ZIP!" (
        echo [ERROR] ZIP file not found after download.
        pause & exit /b 1
    )
    for %%S in ("!LLAMA_ZIP!") do if %%~zS lss 1000000 (
        echo [ERROR] Downloaded file too small, download corrupted.
        pause & exit /b 1
    )
    echo [OK] Download complete.

    if exist "!LLAMA_TMP!" rd /s /q "!LLAMA_TMP!"
    mkdir "!LLAMA_TMP!"

    echo [INFO] Extracting...
    powershell -command "Expand-Archive -LiteralPath 'deps\llama-server.zip' -DestinationPath 'deps\llama-extract' -Force"

    set FOUND=0
    for /r "!LLAMA_TMP!" %%f in (llama-server.exe) do (
        if "!FOUND!"=="0" (
            for %%d in ("%%~dpf.") do xcopy /Y /Q "%%~dpf*" "deps\" >nul
            set FOUND=1
        )
    )
    if "!FOUND!"=="0" (
        echo [ERROR] llama-server.exe not found in archive.
        pause & exit /b 1
    )

    rd /s /q "!LLAMA_TMP!" 2>nul
    del "!LLAMA_ZIP!" 2>nul
    echo [OK] llama-server.exe installed.
) else (
    echo [INFO] llama-server.exe already present.
)

:: ---------- DOWNLOAD MODEL FROM HUGGINGFACE ----------
set HF_REPO=mradermacher/gemma-4-E4B-it-ultra-uncensored-heretic-GGUF
set HF_FILENAME=gemma-4-E4B-it-ultra-uncensored-heretic.%QUANT%.gguf
set MODEL_FILE=gemma-4-E4B-it-ultra-uncensored-heretic-%QUANT%.gguf
set MODEL_PATH=models\%MODEL_FILE%

if not exist "%MODEL_PATH%" (
    echo [INFO] Downloading model: %MODEL_FILE%
    echo [INFO] From HuggingFace: %HF_REPO%

    python -m pip install huggingface_hub --quiet --user
    if %errorlevel% neq 0 (
        echo [ERROR] Could not install huggingface_hub.
        pause & exit /b 1
    )

    python -c "from huggingface_hub import hf_hub_download; hf_hub_download(repo_id='%HF_REPO%', filename='%HF_FILENAME%', local_dir='models')"
    if %errorlevel% neq 0 (
        echo [ERROR] Model download failed.
        echo Check that the repo exists: https://huggingface.co/%HF_REPO%
        pause & exit /b 1
    )

    :: Rename if needed (huggingface sometimes keeps original name)
    if not exist "%MODEL_PATH%" (
        for %%f in (models\*.gguf) do (
            if /i not "%%~nxf"=="%MODEL_FILE%" (
                ren "%%f" "%MODEL_FILE%"
            )
        )
    )

    echo [OK] Model downloaded.
) else (
    echo [INFO] Model already present: %MODEL_PATH%
)

:: ---------- PYTHON DEPENDENCIES ----------
echo [INFO] Installing Python dependencies...
python -m pip install flask flask-cors requests huggingface_hub --quiet --user
if %errorlevel% neq 0 (
    echo [WARNING] Some dependencies could not be installed.
    echo Run manually: pip install flask flask-cors requests huggingface_hub
)

:: ---------- SAVE CONFIG FOR START.BAT ----------
echo %CTX%> deps\ctx.txt
echo %QUANT%> deps\quant.txt

echo.
echo ============================================
echo   Installation complete!
echo   Run start.bat to launch WormGPT.
echo ============================================
pause
