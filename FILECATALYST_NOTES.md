# FileCatalyst HotFolder Integration Notes

This installer uses FileCatalyst HotFolder in a two-phase process:

## Phase 1: SAVEINF (Interactive)
- Launch the HotFolder installer to open the GUI and capture the chosen settings to an INF file.
- Example (configured in `installer.config.json`):
  - `"saveInfArgs": ["/SAVEINF=filecatalyst_settings.inf"]`

## Phase 2: LOADINF (Silent)
- Immediately re-run the installer for unattended installation using previously saved settings.
- Example flags:
  - `"loadInfArgs": ["/LOADINF=filecatalyst_settings.inf", "/VERYSILENT", "/NORESTART"]`

## Hot Folder Detection
- After SAVEINF/LOADINF completes, the installer parses the generated INF file to extract the configured HotFolder path.
- Keys scanned (configurable):
  - `HotFolder`, `HotFolderPath`, `WatchFolder`, `MonitorPath`, `InputFolder`, `SourceFolder`
- The detected path is injected into application properties using the key configured at `application.properties.cameraproxy.keys.fileCatalystHotFolder`.

## Notes
- Set the FileCatalyst HotFolder URL and SHA256 in `dependencies.filecatalyst` with official distribution details.
- The installer enforces an absolute path and uses `filecatalyst_hotfolder.inf` in the installer directory for SAVE/LOAD operations regardless of the relative name in args.
- The installer will handle absent FileCatalyst (optional) and continue with a placeholder `NOT_CONFIGURED` hot folder value if necessary.
