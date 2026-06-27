# TaskScope

TaskScope is a native macOS Dock and menu bar utility for monitoring running processes and stopping selected tasks without opening Activity Monitor. It includes a GlobalProtect preset for opening, checking, and closing the common GlobalProtect user-facing and helper processes.

It does not uninstall GlobalProtect, delete launch files, rename launch files, or disable the privileged system PanGPS daemon. For GlobalProtect, TaskScope manages the visible app plus the user-level Palo Alto launch agents so the app can stay closed until you launch it again. If PanGPS is missing when you open GlobalProtect, TaskScope asks macOS for admin approval to load the Palo Alto system daemon before opening the UI.

## Build and Run

```bash
./script/build_and_run.sh
```

The script builds the SwiftPM app, stages `dist/TaskScope.app`, and opens it as a regular Dock app with a menu bar extra.
It uses a Release build by default so the menu bar app runs with lower overhead.

## Install Locally

```bash
./script/install.sh
```

The installer builds a Release app, generates the icon, signs the app ad hoc for local use, verifies the signature, copies `TaskScope.app` to `/Applications`, and opens the installed copy.
After a successful install, it removes the temporary `dist/TaskScope.app` staging copy so Finder and Spotlight do not show duplicate TaskScope apps.

After installing, use the app's **Launch at Login** toggle from the installed `/Applications/TaskScope.app` copy.

## Menu Actions

- Searchable process list sorted by CPU usage
- CPU and memory columns
- Create watched app presets and auto-stop rules from the process context menu
- Stop selected user processes after confirmation
- GlobalProtect preset for `GlobalProtect` and user-level helpers
- GlobalProtect user launch-agent unload/restore for close-and-launch control
- GlobalProtect admin prompt to restore protected `PanGPS` when the service is missing
- Refresh Status
- Launch at Login
- Quit TaskScope

The privileged PanGPS daemon is managed by GlobalProtect and launchd. If TaskScope cannot load PanGPS after admin approval, reboot first, then update or reinstall GlobalProtect through your company/IT installer.
