@echo off
setlocal EnableExtensions EnableDelayedExpansion
title AI Pendrive - Local LLM Launcher
color 0B

rem ============================================================================
rem LAUNCHER.BAT - Unified AI Pendrive launcher
rem ============================================================================
rem Reads config.json (written by setup.bat) and starts the llamafile server.
rem
rem If config.json is missing, runs setup.bat first.
rem
rem Supports model switching, profile editing, and a menu for advanced users.
rem ============================================================================

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"
cd /d "%ROOT%"

set "CONFIG=%ROOT%\config.json"
set "LAUNCH_PS=%ROOT%\launcher_core.ps1"

if not exist "%LAUNCH_PS%" (
    echo ERROR: launcher_core.ps1 is missing from "%ROOT%".
    pause
    exit /b 1
)

if not exist "%CONFIG%" (
    echo.
    echo   No configuration found. Running setup first...
    echo.
    call "%ROOT%\setup.bat"
    if not exist "%CONFIG%" (
        echo.
        echo ERROR: Setup did not produce config.json. Aborting.
        pause
        exit /b 1
    )
)

powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%LAUNCH_PS%" -Root "%ROOT%"
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo.
    echo Launcher exited with code %EXIT_CODE%.
    echo.
    pause
)

endlocal
exit /b %EXIT_CODE%