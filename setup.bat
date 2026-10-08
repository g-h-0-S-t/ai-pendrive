@echo off
setlocal EnableExtensions EnableDelayedExpansion
title AI Pendrive Setup Wizard
color 0B

rem ============================================================================
rem SETUP.BAT - AI Pendrive interactive setup wizard
rem ============================================================================
rem Double-click this file to configure AI Pendrive for this machine.
rem
rem Two modes:
rem   1) AUTO     - detects hardware, picks the best profile, downloads
rem                 everything automatically. One-click for newbies.
rem   2) SEMI-AUTO - guided manual mode. Detects hardware, recommends, but
rem                 lets the user pick tier, context, model, port, tools, etc.
rem
rem Both modes:
rem   - detect CPU cores, system RAM, GPU vendor/model/VRAM
rem   - optionally accept a Hugging Face access token (for gated repos)
rem   - download llamafile runtime if missing
rem   - download the recommended (or chosen) GGUF model(s)
rem   - write config.json that launcher.bat and status.bat read
rem ============================================================================

set "ROOT=%~dp0"
rem Strip the trailing backslash that %~dp0 always adds. Otherwise cmd's
rem quoting turns "D:\...\dir\" into an escaped quote and PowerShell sees a
rem literal " inside the path, causing "Illegal characters in path".
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
cd /d "%ROOT%"

set "SETUP_PS=%ROOT%\setup_core.ps1"
set "DETECT_PS=%ROOT%\detect_system.ps1"
set "DOWNLOAD_PS=%ROOT%\download_model.ps1"

if not exist "%SETUP_PS%" (
    echo ERROR: setup_core.ps1 is missing from "%ROOT%".
    echo Re-extract the AI Pendrive package.
    pause
    exit /b 1
)

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SETUP_PS%" -Root "%ROOT%"
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo.
    echo Setup exited with code %EXIT_CODE%.
    echo.
    pause
)

endlocal
exit /b %EXIT_CODE%