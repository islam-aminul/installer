@echo off
setlocal enabledelayedexpansion

REM Main update script - Bifurcation point for different installation types
REM This script auto-detects installation type and calls appropriate update script

echo [%date% %time%] Starting iCamera Proxy Update Process...

REM Set relative paths based on script location
set "SCRIPT_DIR=%~dp0"
set "PROXY_DIR=%SCRIPT_DIR%.."
set "INSTALL_ROOT=%PROXY_DIR%\.."

REM Log file for update process
set "UPDATE_LOG=%SCRIPT_DIR%%~n0.log"
echo [%date% %time%] Update process started >> "%UPDATE_LOG%"

REM Auto-detect installation type
echo [%date% %time%] Detecting installation type...
sc query "iCamera-Proxy" >nul 2>&1
if %errorlevel%==0 (
    echo [%date% %time%] Service-based installation detected
    echo [%date% %time%] Service-based installation detected >> "%UPDATE_LOG%"
    set "INSTALL_TYPE=service"
    set "UPDATE_SCRIPT=update-service-based.bat"
) else (
    echo [%date% %time%] Task schedule-based installation detected
    echo [%date% %time%] Task schedule-based installation detected >> "%UPDATE_LOG%"
    set "INSTALL_TYPE=task"
    set "UPDATE_SCRIPT=update-task-schedule.bat"
)

REM Verify the appropriate update script exists
if not exist "%SCRIPT_DIR%%UPDATE_SCRIPT%" (
    echo [%date% %time%] ERROR: Update script not found: %UPDATE_SCRIPT%
    echo [%date% %time%] ERROR: Update script not found: %UPDATE_SCRIPT% >> "%UPDATE_LOG%"
    pause
    exit /b 1
)

REM Call the appropriate update script
echo [%date% %time%] Calling %UPDATE_SCRIPT%...
echo [%date% %time%] Calling %UPDATE_SCRIPT%... >> "%UPDATE_LOG%"

call "%SCRIPT_DIR%%UPDATE_SCRIPT%"
set "UPDATE_RESULT=%errorlevel%"

if %UPDATE_RESULT%==0 (
    echo [%date% %time%] Update completed successfully
    echo [%date% %time%] Update completed successfully >> "%UPDATE_LOG%"
) else (
    echo [%date% %time%] Update failed with error code: %UPDATE_RESULT%
    echo [%date% %time%] Update failed with error code: %UPDATE_RESULT% >> "%UPDATE_LOG%"
)

echo [%date% %time%] Update process finished
echo [%date% %time%] Update process finished >> "%UPDATE_LOG%"

exit /b %UPDATE_RESULT%
