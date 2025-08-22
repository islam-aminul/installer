@echo off
setlocal enabledelayedexpansion

REM Task Schedule-based Update Script
REM Maintains existing legacy update behavior for scheduled task installations

echo [%date% %time%] Starting Task Schedule-based Update...

REM Set relative paths
set "SCRIPT_DIR=%~dp0"
set "PROXY_DIR=%SCRIPT_DIR%.."
set "INSTALL_ROOT=%PROXY_DIR%\.."
set "UPDATE_LOG=%SCRIPT_DIR%%~n0.log"

echo [%date% %time%] Task schedule update started >> "%UPDATE_LOG%"

REM Find HSQLDB directory and sqltool.rc
echo [%date% %time%] Searching for HSQLDB configuration...
set "HSQLDB_DIR="
set "SQLTOOL_RC="

for /d %%d in ("%INSTALL_ROOT%\hsql*") do (
    if exist "%%d\sqltool.rc" (
        set "HSQLDB_DIR=%%d"
        set "SQLTOOL_RC=%%d\sqltool.rc"
        echo [%date% %time%] Found HSQLDB directory: %%d
        goto :found_hsqldb
    )
)

:found_hsqldb
if "%HSQLDB_DIR%"=="" (
    echo [%date% %time%] ERROR: Could not find HSQLDB directory or sqltool.rc
    echo [%date% %time%] ERROR: Could not find HSQLDB directory or sqltool.rc >> "%UPDATE_LOG%"
    exit /b 1
)

REM Find SQLTool JAR
set "SQLTOOL_JAR="
for %%f in ("%HSQLDB_DIR%\lib\hsqldb*.jar") do (
    set "SQLTOOL_JAR=%%f"
    goto :found_sqltool
)

:found_sqltool
if "%SQLTOOL_JAR%"=="" (
    echo [%date% %time%] ERROR: Could not find SQLTool JAR in %HSQLDB_DIR%\lib
    echo [%date% %time%] ERROR: Could not find SQLTool JAR >> "%UPDATE_LOG%"
    exit /b 1
)

REM Check for SQL update file
if exist "%SCRIPT_DIR%update.sql" (
    echo [%date% %time%] Running SQL updates...
    echo [%date% %time%] Running SQL updates >> "%UPDATE_LOG%"
    
    java -cp "%SQLTOOL_JAR%" org.hsqldb.cmdline.SqlTool --rcFile="%SQLTOOL_RC%" --sql="\i %SCRIPT_DIR%update.sql" db0
    
    if !errorlevel! neq 0 (
        echo [%date% %time%] ERROR: SQL update failed
        echo [%date% %time%] ERROR: SQL update failed >> "%UPDATE_LOG%"
        exit /b 1
    )
    
    echo [%date% %time%] SQL updates completed successfully
    echo [%date% %time%] SQL updates completed successfully >> "%UPDATE_LOG%"
) else (
    echo [%date% %time%] No SQL updates found, skipping database update
    echo [%date% %time%] No SQL updates found >> "%UPDATE_LOG%"
)

REM Replace JAR file if new version exists
if exist "%SCRIPT_DIR%CameraProxy.jar" (
    echo [%date% %time%] Replacing JAR file...
    echo [%date% %time%] Replacing JAR file >> "%UPDATE_LOG%"
    
    REM Backup current JAR
    if exist "%PROXY_DIR%\CameraProxy.jar" (
        copy "%PROXY_DIR%\CameraProxy.jar" "%PROXY_DIR%\CameraProxy.jar.bak" >nul
        echo [%date% %time%] Current JAR backed up
    )
    
    REM Replace with new JAR
    copy "%SCRIPT_DIR%CameraProxy.jar" "%PROXY_DIR%\CameraProxy.jar" >nul
    if !errorlevel! neq 0 (
        echo [%date% %time%] ERROR: Failed to replace JAR file
        echo [%date% %time%] ERROR: Failed to replace JAR file >> "%UPDATE_LOG%"
        exit /b 1
    )
    
    echo [%date% %time%] JAR file replaced successfully
    echo [%date% %time%] JAR file replaced successfully >> "%UPDATE_LOG%"
) else (
    echo [%date% %time%] No new JAR file found, skipping JAR replacement
    echo [%date% %time%] No new JAR file found >> "%UPDATE_LOG%"
)

REM Update configuration files if they exist
if exist "%SCRIPT_DIR%proxy-details.properties" (
    echo [%date% %time%] Updating proxy-details.properties...
    copy "%SCRIPT_DIR%proxy-details.properties" "%PROXY_DIR%\proxy-details.properties" >nul
    echo [%date% %time%] proxy-details.properties updated >> "%UPDATE_LOG%"
)

if exist "%SCRIPT_DIR%logback.xml" (
    echo [%date% %time%] Updating logback.xml...
    copy "%SCRIPT_DIR%logback.xml" "%PROXY_DIR%\logback.xml" >nul
    echo [%date% %time%] logback.xml updated >> "%UPDATE_LOG%"
)

REM Copy any other configuration files
for %%f in ("%SCRIPT_DIR%*.properties" "%SCRIPT_DIR%*.xml") do (
    if not "%%~nxf"=="update.sql" if not "%%~nxf"=="CameraProxy.jar" (
        if exist "%%f" (
            echo [%date% %time%] Updating %%~nxf...
            copy "%%f" "%PROXY_DIR%\%%~nxf" >nul
            echo [%date% %time%] %%~nxf updated >> "%UPDATE_LOG%"
        )
    )
)

echo [%date% %time%] Task schedule-based update completed successfully
echo [%date% %time%] Task schedule-based update completed >> "%UPDATE_LOG%"

exit /b 0
