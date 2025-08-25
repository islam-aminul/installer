@echo off
setlocal enabledelayedexpansion

:: =============================================================================
:: iCamera Proxy - Non-Admin User Installation Script
:: Installs to user's AppData directory without requiring administrator rights
:: =============================================================================

title iCamera Proxy - User Installation

echo.
echo ========================================================================
echo                    iCamera Proxy - User Installation
echo ========================================================================
echo.
echo This script will install iCamera Proxy to your user directory:
echo %USERPROFILE%\AppData\Local\iCamera
echo.
echo Components to be installed:
echo - Java Runtime Environment (JRE)
echo - FFmpeg Media Processing
echo - HSQLDB Database
echo - iCamera Proxy Application
echo - Start/Stop Scripts and Desktop Shortcut
echo.
echo ========================================================================
echo.

:: Set installation paths
set "INSTALL_ROOT=%USERPROFILE%\AppData\Local\iCamera"
set "PROXY_DIR=%INSTALL_ROOT%\proxy"
set "JRE_DIR=%INSTALL_ROOT%\jre"
set "FFMPEG_DIR=%INSTALL_ROOT%\ffmpeg"
set "HSQLDB_DIR=%INSTALL_ROOT%\hsqldb"
set "LOGS_DIR=%INSTALL_ROOT%\logs"
set "CONFIG_DIR=%INSTALL_ROOT%\config"
set "SCRIPT_DIR=%~dp0"

:: Check for required files
echo [1/7] Checking installation files...
if not exist "%SCRIPT_DIR%7zr.exe" (
    echo ERROR: 7zr.exe not found in script directory
    goto :error_exit
)
if not exist "%SCRIPT_DIR%CameraProxy.jar" (
    echo ERROR: CameraProxy.jar not found in script directory
    goto :error_exit
)
echo - All required files found

:: Create installation directories
echo.
echo [2/7] Creating installation directories...
if not exist "%INSTALL_ROOT%" mkdir "%INSTALL_ROOT%"
if not exist "%PROXY_DIR%" mkdir "%PROXY_DIR%"
if not exist "%JRE_DIR%" mkdir "%JRE_DIR%"
if not exist "%FFMPEG_DIR%" mkdir "%FFMPEG_DIR%"
if not exist "%HSQLDB_DIR%" mkdir "%HSQLDB_DIR%"
if not exist "%LOGS_DIR%" mkdir "%LOGS_DIR%"
if not exist "%CONFIG_DIR%" mkdir "%CONFIG_DIR%"
echo - Installation directories created

:: Extract JRE
echo.
echo [3/7] Extracting Java Runtime Environment...
for %%f in ("%SCRIPT_DIR%amazon-corretto-*.zip" "%SCRIPT_DIR%corretto*.zip" "%SCRIPT_DIR%openjdk*.zip" "%SCRIPT_DIR%jre*.zip") do (
    if exist "%%f" (
        echo - Extracting %%~nxf...
        "%SCRIPT_DIR%7zr.exe" x "%%f" -o"%JRE_DIR%" -y >nul 2>&1
        if !errorlevel! neq 0 (
            echo ERROR: Failed to extract JRE
            goto :error_exit
        )
        goto :jre_extracted
    )
)
echo ERROR: No JRE archive found
goto :error_exit
:jre_extracted
echo - JRE extracted successfully

:: Extract FFmpeg
echo.
echo [4/7] Extracting FFmpeg...
for %%f in ("%SCRIPT_DIR%ffmpeg*.7z" "%SCRIPT_DIR%ffmpeg*.zip") do (
    if exist "%%f" (
        echo - Extracting %%~nxf...
        "%SCRIPT_DIR%7zr.exe" x "%%f" -o"%FFMPEG_DIR%" -y >nul 2>&1
        if !errorlevel! neq 0 (
            echo ERROR: Failed to extract FFmpeg
            goto :error_exit
        )
        goto :ffmpeg_extracted
    )
)
echo ERROR: No FFmpeg archive found
goto :error_exit
:ffmpeg_extracted
echo - FFmpeg extracted successfully

:: Extract and setup HSQLDB
echo.
echo [5/7] Setting up HSQLDB Database...
for %%f in ("%SCRIPT_DIR%hsqldb*.zip") do (
    if exist "%%f" (
        echo - Extracting %%~nxf...
        "%SCRIPT_DIR%7zr.exe" x "%%f" -o"%HSQLDB_DIR%" -y >nul 2>&1
        if !errorlevel! neq 0 (
            echo ERROR: Failed to extract HSQLDB
            goto :error_exit
        )
        goto :hsqldb_extracted
    )
)
echo ERROR: No HSQLDB archive found
goto :error_exit
:hsqldb_extracted

:: Create HSQLDB configuration
echo - Creating database configuration...
mkdir "%HSQLDB_DIR%\data" >nul 2>&1

:: Create sqltool.rc
echo # HSQLDB SQL Tool Configuration > "%HSQLDB_DIR%\sqltool.rc"
echo urlid db0 >> "%HSQLDB_DIR%\sqltool.rc"
echo url jdbc:hsqldb:hsql://localhost:9001/db0 >> "%HSQLDB_DIR%\sqltool.rc"
echo username SA >> "%HSQLDB_DIR%\sqltool.rc"
echo password >> "%HSQLDB_DIR%\sqltool.rc"

:: Create server.properties
echo server.database.0=file:%HSQLDB_DIR:\=/%/data/db0 > "%HSQLDB_DIR%\server.properties"
echo server.dbname.0=db0 >> "%HSQLDB_DIR%\server.properties"
echo server.port=9001 >> "%HSQLDB_DIR%\server.properties"
echo server.silent=true >> "%HSQLDB_DIR%\server.properties"
echo server.trace=false >> "%HSQLDB_DIR%\server.properties"

:: Initialize database if scripts exist
if exist "%SCRIPT_DIR%database-scripts\create.script" (
    echo - Copying database initialization scripts...
    xcopy "%SCRIPT_DIR%database-scripts\*" "%HSQLDB_DIR%\data\" /Y >nul 2>&1
)
if exist "%SCRIPT_DIR%CameraProxy.sql" (
    copy "%SCRIPT_DIR%CameraProxy.sql" "%HSQLDB_DIR%\" >nul 2>&1
)
echo - HSQLDB setup completed

:: Copy application files
echo.
echo [6/7] Installing application files...
copy "%SCRIPT_DIR%CameraProxy.jar" "%PROXY_DIR%\" >nul 2>&1
if exist "%SCRIPT_DIR%proxy-details.properties" (
    copy "%SCRIPT_DIR%proxy-details.properties" "%PROXY_DIR%\" >nul 2>&1
) else (
    :: Create default proxy-details.properties
    echo # iCamera Proxy Configuration > "%PROXY_DIR%\proxy-details.properties"
    echo url=jdbc:hsqldb:hsql://localhost:9001/db0 >> "%PROXY_DIR%\proxy-details.properties"
    echo filecatalyst.hot_folders= >> "%PROXY_DIR%\proxy-details.properties"
    echo filecatalyst.install_dir= >> "%PROXY_DIR%\proxy-details.properties"
)
if exist "%SCRIPT_DIR%logback.xml" (
    copy "%SCRIPT_DIR%logback.xml" "%PROXY_DIR%\" >nul 2>&1
)
echo - Application files copied

:: Create start/stop scripts
echo.
echo [7/7] Creating start/stop scripts and desktop shortcut...

:: Find Java executable
set "JAVA_EXE="
for /d %%d in ("%JRE_DIR%\*") do (
    if exist "%%d\bin\java.exe" (
        set "JAVA_EXE=%%d\bin\java.exe"
        goto :java_found
    )
)
:java_found

:: Find FFmpeg executable
set "FFMPEG_EXE="
for /d %%d in ("%FFMPEG_DIR%\*") do (
    if exist "%%d\bin\ffmpeg.exe" (
        set "FFMPEG_EXE=%%d\bin"
        goto :ffmpeg_found
    )
)
:ffmpeg_found

:: Find HSQLDB JAR
set "HSQLDB_JAR="
for /d %%d in ("%HSQLDB_DIR%\*") do (
    if exist "%%d\lib\hsqldb.jar" (
        set "HSQLDB_JAR=%%d\lib\hsqldb.jar"
        goto :hsqldb_found
    )
)
:hsqldb_found

:: Create start-database.bat
echo @echo off > "%INSTALL_ROOT%\start-database.bat"
echo title iCamera Database Server >> "%INSTALL_ROOT%\start-database.bat"
echo cd /d "%HSQLDB_DIR%" >> "%INSTALL_ROOT%\start-database.bat"
echo echo Starting HSQLDB Database Server... >> "%INSTALL_ROOT%\start-database.bat"
echo "%JAVA_EXE%" -cp "%HSQLDB_JAR%" org.hsqldb.server.Server --database.0 file:data/db0 --dbname.0 db0 --port 9001 >> "%INSTALL_ROOT%\start-database.bat"

:: Create stop-database.bat
echo @echo off > "%INSTALL_ROOT%\stop-database.bat"
echo title Stop iCamera Database >> "%INSTALL_ROOT%\stop-database.bat"
echo cd /d "%HSQLDB_DIR%" >> "%INSTALL_ROOT%\stop-database.bat"
echo echo Stopping HSQLDB Database Server... >> "%INSTALL_ROOT%\stop-database.bat"
echo "%JAVA_EXE%" -cp "%HSQLDB_JAR%" org.hsqldb.util.SqlTool --rcFile=sqltool.rc db0 --sql="SHUTDOWN;" >> "%INSTALL_ROOT%\stop-database.bat"
echo timeout /t 3 >> "%INSTALL_ROOT%\stop-database.bat"

:: Create start-proxy.bat
echo @echo off > "%INSTALL_ROOT%\start-proxy.bat"
echo title iCamera Proxy Server >> "%INSTALL_ROOT%\start-proxy.bat"
echo setlocal >> "%INSTALL_ROOT%\start-proxy.bat"
echo. >> "%INSTALL_ROOT%\start-proxy.bat"
echo :: Set environment variables >> "%INSTALL_ROOT%\start-proxy.bat"
echo set "JAVA_HOME=%JRE_DIR%" >> "%INSTALL_ROOT%\start-proxy.bat"
echo set "PATH=%FFMPEG_EXE%;%%PATH%%" >> "%INSTALL_ROOT%\start-proxy.bat"
echo. >> "%INSTALL_ROOT%\start-proxy.bat"
echo cd /d "%PROXY_DIR%" >> "%INSTALL_ROOT%\start-proxy.bat"
echo echo Starting iCamera Proxy Server... >> "%INSTALL_ROOT%\start-proxy.bat"
echo echo Java: %JAVA_EXE% >> "%INSTALL_ROOT%\start-proxy.bat"
echo echo FFmpeg: %FFMPEG_EXE% >> "%INSTALL_ROOT%\start-proxy.bat"
echo echo. >> "%INSTALL_ROOT%\start-proxy.bat"
echo "%JAVA_EXE%" -jar CameraProxy.jar >> "%INSTALL_ROOT%\start-proxy.bat"

:: Create desktop shortcut
set "DESKTOP=%USERPROFILE%\Desktop"
echo [InternetShortcut] > "%DESKTOP%\iCamera Proxy.url"
echo URL=file:///%INSTALL_ROOT:\=/%/start-proxy.bat >> "%DESKTOP%\iCamera Proxy.url"
echo IconFile=%INSTALL_ROOT%\proxy\CameraProxy.jar >> "%DESKTOP%\iCamera Proxy.url"
echo IconIndex=0 >> "%DESKTOP%\iCamera Proxy.url"

echo - Start/stop scripts created
echo - Desktop shortcut created

:: Installation complete
echo.
echo ========================================================================
echo                        INSTALLATION COMPLETED
echo ========================================================================
echo.
echo Installation Directory: %INSTALL_ROOT%
echo.
echo To start iCamera Proxy:
echo 1. Run: %INSTALL_ROOT%\start-database.bat
echo 2. Wait for database to start, then run: %INSTALL_ROOT%\start-proxy.bat
echo 3. Or use the desktop shortcut: iCamera Proxy
echo.
echo To stop iCamera Proxy:
echo 1. Close the proxy application
echo 2. Run: %INSTALL_ROOT%\stop-database.bat
echo.
echo Log files will be created in: %LOGS_DIR%
echo Configuration files are in: %CONFIG_DIR%
echo.
echo ========================================================================
echo.
pause
goto :eof

:error_exit
echo.
echo ========================================================================
echo                           INSTALLATION FAILED
echo ========================================================================
echo.
echo Please check the error message above and ensure all required files
echo are present in the script directory.
echo.
pause
exit /b 1
