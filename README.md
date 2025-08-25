# iCamera Proxy Installer (Admin-Only, Windows Services)

This installer deploys the iCamera Proxy system as Windows services with HSQLDB database. All behavior is configuration-driven via `installer.config.json` with no hardcoded values.

## Key Features
- **Admin-Only Installation**: Requires Administrator privileges (shows UAC prompt automatically)
- **Windows Services**: Uses Apache Procrun for robust service management
- **Database Integration**: HSQLDB with dynamic port allocation and initialization
- **Dependency Management**: Automated download/validation of JRE, FFmpeg, FileCatalyst
- **Update Mechanism**: Service-safe update scripts with legacy compatibility
- **Configuration-Driven**: All behavior controlled by `installer.config.json`

## Files Structure
```
installer/
├── installer.config.json          # Master configuration
├── iCameraProxyInstaller.ps1      # Main installer script
├── update-scripts/                # Update mechanism
│   ├── update.bat                 # Main update script (auto-detects type)
│   ├── update-service-based.bat   # Service-based updates
│   └── update-task-schedule.bat   # Legacy scheduled task updates
└── App payload files:
    ├── CameraProxy.jar
    ├── proxy-details.properties
    ├── logback.xml
    └── CameraProxy.sql
```

## Execution Modes
- **Interactive** (default): Shows UI prompts and progress dialogs
- **`--quiet`**: Unattended installation with minimal output
- **`--uninstall`**: Removes all installed components and services

**Exit Codes:**
- `0` = Success
- `1` = General failure  
- `2` = Insufficient privileges (elevation denied)
- `3` = Another installer instance running

## Configuration Overview
See `installer.config.json` for a complete example. Key sections:

- `metadata`: Product identity for registry uninstall entry.
- `networkChecks.urls`: List of HTTPS endpoints for connectivity validation.
- `paths`: Location templates. `<Install Root>` token is resolved dynamically at runtime.
- `application.files`: Source→destination copy list. Sources are relative to the installer directory.
- `application.properties`: Property injection into files (e.g., HSQLDB port, FileCatalyst hot folder).
- `dependencies`: Artifacts to install (JRE, FFMPEG, Procrun, HSQLDB, FileCatalyst). Each has a `fileName`, optional `url`, `sha256`, and `target`.
- `services`: Windows Services configuration (via Apache Procrun). Services are named with `iCamera-` prefix (e.g., `iCamera-HSQLDB`, `iCamera-CameraProxy`).
- `customCommands`: `preInstall` and `postInstall` hooks. Commands defined as `{ command, arguments[], workingDirectory, continueOnError }`.
- `uninstall`: Optional external uninstaller command(s) and uninstall registry key.

## Installation Flow (End-to-End)

### Phase 1: Initialization & Validation
1. **Admin Privilege Check**: Automatically shows UAC elevation prompt if not running as admin
2. **Instance Lock**: Prevents multiple installer instances from running simultaneously
3. **Configuration Loading**: Reads and validates `installer.config.json`
4. **System Prerequisites**: Checks Windows version, PowerShell version, disk space, RAM

### Phase 2: Environment Setup
5. **Drive Selection**: Interactive drive selection or defaults to C: in quiet mode
6. **Directory Creation**: Creates `C:\iCamera\` structure with subdirectories
7. **Permission Setup**: Sets ACLs granting SYSTEM full control with inheritance
8. **Legacy Cleanup**: Removes old scheduled tasks and previous installations

### Phase 3: Dependency Acquisition
9. **Network Connectivity**: Tests internet connection to dependency URLs
10. **Dependency Download/Validation**: 
    - Java Runtime Environment (JRE)
    - Apache Procrun (Windows service wrapper)
    - HSQLDB (Database server)
    - FFmpeg (Media processing)
    - FileCatalyst (File transfer - interactive setup)
11. **SHA256 Verification**: Validates all downloaded packages
12. **Extraction & Installation**: Unpacks dependencies to target directories

### Phase 4: Database Setup
13. **Port Allocation**: Finds available port for HSQLDB (default range 9001-9100)
14. **Database Initialization**: Runs SQL scripts to create schema and initial data
15. **Connection Testing**: Validates database connectivity

### Phase 5: Service Registration
16. **HSQLDB Service**: Registers `iCamera-HSQLDB` Windows service
17. **Proxy Service**: Registers `iCamera-CameraProxy` Windows service with:
    - Dynamic log paths (`--LogPath`, `--StdOutput`, `--StdError`)
    - JVM parameters and system properties
    - Service recovery settings (restart on failure)
    - Delayed auto-start configuration

### Phase 6: Configuration & Startup
18. **Property File Generation**: Creates `proxy-details.properties` with dynamic values
19. **Logging Configuration**: Deploys `logback.xml` with proper paths
20. **Service Startup**: Starts both HSQLDB and Proxy services
21. **Startup Validation**: Verifies services are running correctly

### Phase 7: Finalization
22. **Update Scripts**: Copies update mechanism to installation directory
23. **Start/Stop Scripts**: Generates service management batch files
24. **Registry Entry**: Creates uninstall entry in Windows registry
25. **Installation Complete**: Shows success message and service status

## Placeholders
- `<Install Root>`: Resolved to the chosen root directory (e.g., `C:\iCamera`)
- `${DatabasePort}`: Resolved to the dynamically-selected HSQLDB TCP port

## JVM / System Properties Samples
Update these in `services.iCameraProxy.jvmOptions`:
- `initialHeapSize`: e.g., `256m`
- `maximumHeapSize`: e.g., `1024m`
- `customParameters`: e.g.,
  - `-XX:+UseG1GC`
  - `-XX:MaxGCPauseMillis=200`
  - `-Djava.awt.headless=true`
  - `-Dfile.encoding=UTF-8`
- `systemProperties` (key-value map). Examples:
  - `proxy_home`: `<Install Root>\\proxy`
  - `logback.configurationFile`: `<Install Root>\\proxy\\logback.xml`
  - `db.port`: `${DatabasePort}`

## HSQLDB Initialization
- Port range configured in `dependencies.hsqldb.portRange`.
- SQL init scripts configured in `dependencies.hsqldb.sqlInitScripts` (paths can contain `<Install Root>`).

## FileCatalyst HotFolder
- The installer is executed twice: once with `/SAVEINF` to capture settings interactively, then with `/LOADINF` for silent install.
- The HotFolder path is extracted by parsing the generated `.inf` file (e.g., `filecatalyst_hotfolder.inf`) using keys listed in `dependencies.filecatalyst.hotFolderDetectionKeys`.
- Configure the dependency under `dependencies.filecatalyst` with appropriate `url`, `sha256`, `target`, and optional `search.patterns`/`search.extensions` for local discovery.

## Checksums
All downloads are verified against the `sha256` specified for each dependency. Replace `REPLACE_WITH_SHA256` placeholders with real checksums.

## Update Mechanism

The installer includes a sophisticated update system that maintains backward compatibility:

### Update Scripts Structure
- **`update.bat`**: Main bifurcation script that auto-detects installation type
- **`update-service-based.bat`**: For Windows service installations (new method)
- **`update-task-schedule.bat`**: For legacy scheduled task installations

### Update Process
1. **Auto-Detection**: Determines if installation uses services or scheduled tasks
2. **Service-Safe Updates**: Attempts direct JAR replacement first, falls back to service restart only if needed
3. **Smart Property Updates**: Only updates new/changed properties in `proxy-details.properties`
4. **Database Updates**: Runs SQL scripts against HSQLDB using relative path discovery
5. **Configuration Replacement**: Completely replaces `logback.xml` with new version

### Legacy Compatibility
- Maintains existing `Proxy_Update` folder structure
- Preserves original update.bat naming for backward compatibility
- Supports both service-based and scheduled task-based installations

## Security & Permissions

### Access Control
- **SYSTEM Account**: Full control with container and object inheritance
- **Install Directories**: Restrictive ACLs on sensitive configuration files
- **Service Isolation**: Services run under appropriate system accounts
- **Log Security**: Secure logging with proper file permissions

### Admin Requirements
- **UAC Integration**: Automatic elevation prompt if not running as admin
- **Privilege Validation**: Strict admin-only installation enforcement
- **Service Management**: Requires admin rights for service registration/management

## Uninstall Process

### Registry Integration
- Creates uninstall entry under `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\iCameraProxy`
- `UninstallString` calls installer with `--uninstall` parameter
- Appears in Windows "Programs and Features"

### Cleanup Actions
1. **Service Removal**: Stops and removes all registered Windows services
2. **Directory Cleanup**: Removes installation directories and files
3. **Registry Cleanup**: Removes uninstall registry entries
4. **Legacy Cleanup**: Removes any remaining scheduled tasks from previous versions

## Logging & Troubleshooting

### Log Locations
- **Installer Log**: `<Install Root>\logs\installer.log`
- **Service Logs**: `<Install Root>\logs\<ServiceName>-stdout.log` and `<ServiceName>-stderr.log`
- **Database Logs**: HSQLDB logs in database directory

### Common Issues
- **Permission Errors**: Ensure running as Administrator
- **Port Conflicts**: HSQLDB will find alternative ports in range 9001-9100
- **Service Startup**: Check Windows Event Log for service-specific errors
- **Dependency Downloads**: Verify internet connectivity and firewall settings

## Usage Examples

### Interactive Installation
```powershell
# Right-click "Run as Administrator" or double-click (UAC prompt will appear)
powershell -ExecutionPolicy Bypass -File .\iCameraProxyInstaller.ps1
```

### Unattended Installation
```powershell
# Must run from elevated PowerShell prompt
powershell -ExecutionPolicy Bypass -File .\iCameraProxyInstaller.ps1 --quiet
```

### Uninstallation
```powershell
# Can also be triggered from Windows "Programs and Features"
powershell -ExecutionPolicy Bypass -File .\iCameraProxyInstaller.ps1 --uninstall
```

## Configuration Requirements

Before running the installer:

1. **Update Dependencies**: Replace `REPLACE_WITH_SHA256` placeholders with actual SHA256 checksums
2. **Verify URLs**: Ensure all dependency URLs in `installer.config.json` are accessible
3. **Application Files**: Ensure all required application files are present in installer directory
4. **JVM Settings**: Adjust heap sizes and JVM parameters in configuration as needed
5. **Network Access**: Ensure internet connectivity for dependency downloads
