# iCamera Proxy Installer Configuration

This project is fully configuration-driven. All installer behavior is controlled by `installer.config.json`. No product-specific values are hardcoded in the PowerShell script.

## Files
- `installer.config.json` – Master configuration for the installer
- `iCameraProxyInstaller.ps1` – PowerShell installer (reads all values from config)
- App payload (expected in the same folder):
  - `CameraProxy.jar`
  - `cameraproxy.properties`
  - `logback.xml`
  - `cameraproxy.sql`
  - `hsqldb-2.7.4.zip` (if using local HSQLDB package)

## Modes
- Interactive (default)
- `--quiet` unattended
- `--uninstall` removal

Exit codes: 0 success, 1 general failure, 2 insufficient privileges (elevation denied), 3 another installer instance is running

## Configuration Overview
See `installer.config.json` for a complete example. Key sections:

- `metadata`: Product identity for registry uninstall entry.
- `networkChecks.urls`: List of HTTPS endpoints for connectivity validation.
- `paths`: Location templates. `<Install Root>` token is resolved dynamically at runtime.
- `application.files`: Source→destination copy list. Sources are relative to the installer directory.
- `application.properties`: Property injection into files (e.g., HSQLDB port, FileCatalyst hot folder).
- `dependencies`: Artifacts to install (JRE, FFMPEG, Procrun, HSQLDB, FileCatalyst). Each has a `fileName`, optional `url`, `sha256`, and `target`.
- `services` / `tasks`: Admin-level Windows Services (via Procrun) and user-level Scheduled Tasks equivalents.
- `customCommands`: `preInstall` and `postInstall` hooks. Commands defined as `{ command, arguments[], workingDirectory, continueOnError }`.
- `uninstall`: Optional external uninstaller command(s) and uninstall registry key.

## Placeholders
- `<Install Root>`: Resolved by the installer to the chosen root directory (e.g., `C:\iCamera` or `%LOCALAPPDATA%\iCamera` in user-level mode).
- `${DatabasePort}`: Resolved to the dynamically-selected HSQLDB TCP port.

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

## Drive Selection & Legacy Cleanup
- Interactive mode lists all fixed drives with free space; recommends the largest free drive.
- Quiet mode defaults to `C:`.
- Legacy cleanup removes `iCameraProcessMonitor` task and any `:\iCamera` directories (after confirmation in interactive mode).

## Uninstall Registry Entry
Created under `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\iCameraProxy` (or `HKCU` when needed). `UninstallString` calls the installer with `--uninstall`.

## Security & Logging
- Logs written to `<Install Root>\\logs\\installer.log`.
- Sensitive config files get restrictive ACLs.

## Next Steps
1. Replace dependency URLs and `sha256` values with the correct ones.
2. Adjust JVM `customParameters` and `systemProperties` as needed.
3. Ensure all application files exist in this folder or update `application.files` paths accordingly.
4. Run the installer:
   - Interactive: `powershell -ExecutionPolicy Bypass -File .\iCameraProxyInstaller.ps1`
   - Quiet: `powershell -ExecutionPolicy Bypass -File .\iCameraProxyInstaller.ps1 --quiet`
   - Uninstall: `powershell -ExecutionPolicy Bypass -File .\iCameraProxyInstaller.ps1 --uninstall`
