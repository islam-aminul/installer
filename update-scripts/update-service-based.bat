@echo off
setlocal enabledelayedexpansion

REM Service-based Update Script
REM Attempts direct JAR replacement first, falls back to service stop/start if needed

echo [%date% %time%] Starting Service-based Update...

REM Set relative paths
set "SCRIPT_DIR=%~dp0"
set "PROXY_DIR=%SCRIPT_DIR%.."
set "INSTALL_ROOT=%PROXY_DIR%\.."
set "UPDATE_LOG=%SCRIPT_DIR%%~n0.log"

echo [%date% %time%] Service-based update started >> "%UPDATE_LOG%"

REM Find HSQLDB directory and sqltool.rc
echo [%date% %time%] Searching for HSQLDB configuration...
set "HSQLDB_DIR="
set "SQLTOOL_RC="
set "SERVER_PROPERTIES="

for /d %%d in ("%INSTALL_ROOT%\hsql*") do (
    if exist "%%d\sqltool.rc" (
        set "HSQLDB_DIR=%%d"
        set "SQLTOOL_RC=%%d\sqltool.rc"
        echo [%date% %time%] Found HSQLDB directory: %%d
        
        REM Look for server properties file
        for %%p in ("%%d\server.properties" "%%d\hsqldb.properties") do (
            if exist "%%p" (
                set "SERVER_PROPERTIES=%%p"
                echo [%date% %time%] Found server properties: %%p
            )
        )
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

REM Run SQL updates if available
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

REM Update proxy-details.properties with only new/changed properties
if exist "%SCRIPT_DIR%proxy-details.properties" (
    echo [%date% %time%] Updating proxy-details.properties with new properties...
    call :update_properties "%PROXY_DIR%\proxy-details.properties" "%SCRIPT_DIR%proxy-details.properties"
    echo [%date% %time%] proxy-details.properties updated >> "%UPDATE_LOG%"
)

REM Replace logback.xml completely
if exist "%SCRIPT_DIR%logback.xml" (
    echo [%date% %time%] Replacing logback.xml...
    copy "%SCRIPT_DIR%logback.xml" "%PROXY_DIR%\logback.xml" >nul
    echo [%date% %time%] logback.xml replaced >> "%UPDATE_LOG%"
)

REM Replace JAR file if new version exists
if exist "%SCRIPT_DIR%CameraProxy.jar" (
    echo [%date% %time%] Attempting direct JAR replacement...
    echo [%date% %time%] Attempting direct JAR replacement >> "%UPDATE_LOG%"
    
    REM Backup current JAR
    if exist "%PROXY_DIR%\CameraProxy.jar" (
        copy "%PROXY_DIR%\CameraProxy.jar" "%PROXY_DIR%\CameraProxy.jar.bak" >nul
        echo [%date% %time%] Current JAR backed up
    )
    
    REM Try direct replacement first
    copy "%SCRIPT_DIR%CameraProxy.jar" "%PROXY_DIR%\CameraProxy.jar" >nul 2>&1
    if !errorlevel!==0 (
        echo [%date% %time%] Direct JAR replacement successful
        echo [%date% %time%] Direct JAR replacement successful >> "%UPDATE_LOG%"
        goto :jar_replaced
    )
    
    REM Direct replacement failed, try service-based approach
    echo [%date% %time%] Direct replacement failed, attempting service-based replacement...
    echo [%date% %time%] Direct replacement failed, trying service approach >> "%UPDATE_LOG%"
    
    REM Stop the service
    echo [%date% %time%] Stopping iCamera-Proxy service...
    sc stop "iCamera-Proxy" >nul 2>&1
    
    REM Wait for service to stop (max 30 seconds)
    set /a "wait_count=0"
    :wait_stop
    sc query "iCamera-Proxy" | find "STOPPED" >nul
    if !errorlevel!==0 goto :service_stopped
    
    set /a "wait_count+=1"
    if !wait_count! gtr 30 (
        echo [%date% %time%] ERROR: Service did not stop within 30 seconds
        echo [%date% %time%] ERROR: Service stop timeout >> "%UPDATE_LOG%"
        goto :restore_jar
    )
    
    timeout /t 1 >nul
    goto :wait_stop
    
    :service_stopped
    echo [%date% %time%] Service stopped successfully
    
    REM Replace JAR while service is stopped
    copy "%SCRIPT_DIR%CameraProxy.jar" "%PROXY_DIR%\CameraProxy.jar" >nul
    if !errorlevel! neq 0 (
        echo [%date% %time%] ERROR: Failed to replace JAR even with service stopped
        echo [%date% %time%] ERROR: JAR replacement failed >> "%UPDATE_LOG%"
        goto :restore_jar
    )
    
    echo [%date% %time%] JAR replaced successfully
    echo [%date% %time%] JAR replaced with service stopped >> "%UPDATE_LOG%"
    
    REM Start the service
    echo [%date% %time%] Starting iCamera-Proxy service...
    sc start "iCamera-Proxy" >nul 2>&1
    
    REM Wait for service to start (max 30 seconds)
    set /a "wait_count=0"
    :wait_start
    sc query "iCamera-Proxy" | find "RUNNING" >nul
    if !errorlevel!==0 (
        echo [%date% %time%] Service started successfully
        echo [%date% %time%] Service started successfully >> "%UPDATE_LOG%"
        goto :jar_replaced
    )
    
    set /a "wait_count+=1"
    if !wait_count! gtr 30 (
        echo [%date% %time%] WARNING: Service did not start within 30 seconds, but JAR was replaced
        echo [%date% %time%] WARNING: Service start timeout >> "%UPDATE_LOG%"
        goto :jar_replaced
    )
    
    timeout /t 1 >nul
    goto :wait_start
    
    :restore_jar
    REM Restore backup JAR if replacement failed
    if exist "%PROXY_DIR%\CameraProxy.jar.bak" (
        echo [%date% %time%] Restoring backup JAR...
        copy "%PROXY_DIR%\CameraProxy.jar.bak" "%PROXY_DIR%\CameraProxy.jar" >nul
        echo [%date% %time%] Backup JAR restored >> "%UPDATE_LOG%"
        
        REM Try to start service with original JAR
        sc start "iCamera-Proxy" >nul 2>&1
    )
    exit /b 1
    
    :jar_replaced
    echo [%date% %time%] JAR file replacement completed
) else (
    echo [%date% %time%] No new JAR file found, skipping JAR replacement
    echo [%date% %time%] No new JAR file found >> "%UPDATE_LOG%"
)

echo [%date% %time%] Service-based update completed successfully
echo [%date% %time%] Service-based update completed >> "%UPDATE_LOG%"

exit /b 0

REM Function to update properties file with only new/changed properties
:update_properties
set "TARGET_FILE=%~1"
set "SOURCE_FILE=%~2"

if not exist "%TARGET_FILE%" (
    copy "%SOURCE_FILE%" "%TARGET_FILE%" >nul
    goto :eof
)

REM Create temporary file for updated properties
set "TEMP_FILE=%TARGET_FILE%.tmp"
copy "%TARGET_FILE%" "%TEMP_FILE%" >nul

REM Read each property from source file and update target
for /f "usebackq tokens=1,* delims==" %%a in ("%SOURCE_FILE%") do (
    if not "%%a"=="" if not "%%a:~0,1%"=="#" (
        set "PROP_NAME=%%a"
        set "PROP_VALUE=%%b"
        
        REM Remove existing property from temp file
        findstr /v /b "!PROP_NAME!=" "%TEMP_FILE%" > "%TEMP_FILE%.new"
        move "%TEMP_FILE%.new" "%TEMP_FILE%" >nul
        
        REM Add updated property
        echo !PROP_NAME!=!PROP_VALUE!>> "%TEMP_FILE%"
    )
)

REM Replace original with updated file
move "%TEMP_FILE%" "%TARGET_FILE%" >nul
goto :eof
