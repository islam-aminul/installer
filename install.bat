@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
set "PS1=%SCRIPT_DIR%iCameraProxyInstaller.ps1"

if not exist "%PS1%" (
  echo ERROR: Installer script not found: "%PS1%"
  exit /b 1
)

rem Prefer Windows PowerShell (5.1) since the script targets it
where powershell >nul 2>nul
if errorlevel 1 (
  echo ERROR: Windows PowerShell not found in PATH.
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "EXITCODE=%ERRORLEVEL%"

rem If no args were supplied, give the user a chance to read output
if "%~1"=="" (
  echo.
  echo Exit code: %EXITCODE%
  echo Press any key to close...
  pause >nul
)

exit /b %EXITCODE%
