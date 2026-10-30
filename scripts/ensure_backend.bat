@echo off
setlocal
cd /d "%~dp0.."

if not exist ".venv\Scripts\python.exe" (
    echo [SETUP] Creating Athena's Python environment...
    py -3 -m venv .venv
    if errorlevel 1 goto :error
)

set "PYTHON=.venv\Scripts\python.exe"
if not exist "%PYTHON%" (
    echo [ERROR] Python 3 was not found. Install Python 3.10 or newer and try again.
    goto :error
)

"%PYTHON%" -c "import fastapi, uvicorn, multipart, pymupdf, rapidocr, onnxruntime, sqlmodel, httpx, openai, google.genai, yake, dotenv" >nul 2>nul
if errorlevel 1 (
    echo [SETUP] Installing Athena backend and bundled OCR dependencies. First launch may take several minutes...
    "%PYTHON%" -m ensurepip --upgrade
    if errorlevel 1 goto :error
    "%PYTHON%" -m pip install --disable-pip-version-check -r backend\requirements.txt
    if errorlevel 1 goto :error
)

set "PYTHONPATH=backend"
if /i "%~1"=="--serve" (
    echo [START] Athena backend at http://127.0.0.1:8000
    "%PYTHON%" -m uvicorn app.main:app --host 127.0.0.1 --port 8000 --app-dir backend --reload
    exit /b %ERRORLEVEL%
)
echo [OK] Backend dependencies, including bundled OCR, are ready.
exit /b 0

:error
echo [ERROR] Athena backend setup failed. Fix the message above and run this launcher again.
pause
exit /b 1
