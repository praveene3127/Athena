@echo off
set "PATH=C:\src\flutter\bin;%LOCALAPPDATA%\Android\Sdk\platform-tools;%PATH%"
echo ========================================================
echo               ATHENA ALL-IN-ONE LAUNCHER
echo ========================================================

:: 1. Check if backend is running on 8000
netstat -ano | findstr :8000 | findstr LISTENING >nul
if %ERRORLEVEL% equ 0 (
    echo [OK] Athena Backend is already running on port 8000.
) else (
    echo [STARTING] Launching Athena FastAPI Backend...
    start "Athena Backend" cmd /c ""%~dp0ensure_backend.bat" --serve"
    timeout /t 3 >nul
)

:: 2. Check if phone is connected via USB debugging
adb devices 2>nul | findstr /v "List of devices" | findstr "device" >nul
if %ERRORLEVEL% equ 0 (
    echo [OK] Connected phone detected. Forwarding port 8000 to phone...
    adb reverse tcp:8000 tcp:8000
) else (
    echo [INFO] No phone connected via USB debugging. Web mode enabled.
)

:: 3. Check if Flutter Web Server is running on 8080
netstat -ano | findstr :8080 | findstr LISTENING >nul
if %ERRORLEVEL% equ 0 (
    echo [OK] Flutter Web Server is already running on port 8080.
) else (
    echo [STARTING] Launching Athena Web Reader on port 8080...
    start "Athena Web Server" /b cmd /c ""%~dp0..\.venv\Scripts\python.exe" "%~dp0port_8080_forwarder.py""
    timeout /t 2 >nul
    echo [OK] Athena Web Server is online.
)

:: 4. Open Athena in Browser
echo [LAUNCHING] Opening Athena App in your browser...
start http://127.0.0.1:8080

echo ========================================================
echo Desktop URL:        http://127.0.0.1:8080
echo Phone Wi-Fi URL:    See http://127.0.0.1:8000/api/pair-info
echo Backend API URL:    http://127.0.0.1:8000
echo API Docs:           http://127.0.0.1:8000/docs
echo ========================================================
pause
