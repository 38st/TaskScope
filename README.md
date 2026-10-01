# TaskScope

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![macOS 14 deployment target](https://img.shields.io/badge/deployment%20target-macOS%2014-black.svg)](https://support.apple.com/macos)

TaskScope is a native macOS process monitor and task controller that lives in
the Dock and menu bar. It combines a searchable process list with watched-app
presets, lifecycle controls, saved selections, auto-stop rules, notifications,
Shortcuts actions, and process-history charts.

TaskScope's GlobalProtect **Quit All** action automatically disconnects the VPN,
stops the app and its services, and enables **Keep GlobalProtect Off** until you
choose **Open**. The Keep Off toggle uses the same full shutdown. TaskScope uses
Accessibility permission to press the vendor's Disconnect button and waits for
a stable disconnected state before stopping services. If permission is denied,
the control is unavailable, or disconnect cannot be verified, shutdown stops
with an explanation. A menu-bar full stop opens the regular TaskScope window
before controlling GlobalProtect, keeping progress and the complete result visible.
A failed connection can also be stopped when the vendor shows **Connection Failed**
with an enabled **Connect** control and no **Disconnect** control; an **Error**
tooltip alone is insufficient. After confirmation and macOS administrator approval when needed, TaskScope disables
and unloads the known per-user agents and the fixed system `PanGPS` VPN service.
**Open** clears the required disable overrides and
restores the installed login-session VPN service (`pangps`) before the app.
Installations without that agent use the system daemon (`pangpsd`). A session
service can run as root; TaskScope verifies its launchd PID and executable
instead of choosing a service solely from its owner. For installations with a
valid session agent, Open leaves the separate system daemon disabled. After
the first full stop, later Open/Keep Off cycles need no administrator prompt
unless something restores that system service or changes the installed layout.
Turning Keep Off off now performs the same full restoration as Open, starting
the required VPN service and app while preserving the unused system daemon's
disable override. Open also recovers an app window that was launched without
its VPN service, and does not bootstrap a duplicate UI over an existing one.
No uninstall,
reinstall, or changes to vendor files or VPN configuration are needed.

Before automatic disconnect, stopping after VPN use could leave public DNS unavailable,
including after the client showed Disconnected. **Open** restored normal DNS
without reconnecting; stopping that idle service then kept public DNS/HTTPS
working. TaskScope does not rewrite network settings to recover DNS.
The later [automatic Quit All tests](Evidence/GlobalProtect/2026-09-28-quit-all.md)
preserved public DNS/HTTPS through two connected-to-off cycles on that Mac.

Quit App, Quit Helpers, URL Close, and Shortcuts Stop retain their existing
user-process scope. Background Keep Off
enforcement never requests privileges; if the system service returns, its
running state and **Apply Keep Off…** remain visible. Existing Keep Off
preferences from older builds do not authorize a background system stop: choose
Apply Keep Off once to include the VPN service. GlobalProtect layouts and
management policies vary; rejected or unverifiable actions are reported as
failures. Installed-product lifecycle and login/reboot compatibility remain
unverified until recorded in the evidence matrix.

The built-in preset's **Compatibility Self-Check** reads known launch-agent
installation and launchd state, separates user processes from the protected
system service, and includes macOS, TaskScope, and GlobalProtect versions.
Preview, copy, or export its redacted summary without changing lifecycle state.
See [support instructions](SUPPORT.md#collect-globalprotect-compatibility-evidence)
and the [compatibility evidence matrix](GLOBALPROTECT_COMPATIBILITY.md).

> [!IMPORTANT]
> The 1.0.0 repository release provides source and local-development packaging.
> It does not provide a Developer ID-signed or notarized public app download.
> The local release bundle has only been exercised on Apple silicon and must not
> be described as universal or Intel-compatible without separate evidence.

## Requirements and verified scope

- The package declares macOS 14 as its minimum deployment target. That setting
  is not, by itself, evidence that every macOS 14 release has passed runtime QA.
- Swift tools 5.9 or newer can build the package.
- Xcode 26 or newer is required for the full test suite and App Intents metadata
  packaging used by the current scripts.
- Local packaging and runtime checks currently target arm64. SwiftPM builds for
  the architecture of the current Mac; the scripts do not create a universal
  binary.
- The install destination must already exist and be writable. `/Applications`
  may be controlled by an administrator.

The packaging scripts use `TASKSCOPE_CODE_SIGN_IDENTITY` when provided,
otherwise the first available Apple Development identity, and fall back to
ad-hoc signing. A development signature is required for macOS to execute the
packaged App Intents; an ad-hoc build can validate metadata, but Shortcuts
rejects the intents at runtime. Neither signature is a substitute for Developer
ID signing and notarization.

## Build, verify, and run

Build the release executable, stage `dist/build.noindex/TaskScope.app`, and open it:

```bash
./script/build_and_run.sh
```

The local bundle stays in a `.noindex` build folder so Spotlight shows the
installed `/Applications/TaskScope.app` without a duplicate build result.
Staging and startup verification also remove the build's temporary launcher
registration. Running the development app explicitly still launches that copy.

Other modes:

```bash
./script/build_and_run.sh --stage       # stage without opening
./script/build_and_run.sh --verify      # verify the already staged bundle (no rebuild) and its startup
./script/build_and_run.sh --debug       # start the debug executable in LLDB
./script/build_and_run.sh --logs        # stream local process logs
./script/build_and_run.sh --telemetry   # stream local subsystem logs only
```

`--telemetry` is a historical name for a local macOS Unified Log stream. It
does not upload telemetry. Set `BUILD_CONFIGURATION=debug` or
`BUILD_CONFIGURATION=release` to override the configuration where appropriate.
Finder and About TaskScope read their version from `VERSION` and `BUILD_NUMBER`.

Run the complete local quality gate before proposing a change:

```bash
bash -n script/*.sh
swift build -c debug -Xswiftc -warnings-as-errors
swift test
swift test --enable-code-coverage
swift test --scratch-path /tmp/taskscope-release-strict \
  -Xswiftc -warnings-as-errors \
  -Xswiftc -warn-concurrency \
  -Xswiftc -enable-actor-data-race-checks
swift build -c release
./script/test_packaging.sh
git diff --check
```

The packaging test needs Xcode 26 and a macOS environment capable of building
App Intents metadata. See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution
expectations and [RELEASE.md](RELEASE.md) for the maintainer release gate.

## Install, upgrade, and uninstall locally

Build and install the app:

```bash
./script/install.sh
```

Use `--no-open` to install without launching. Set `DEST_DIR` to another existing
writable directory if required:

```bash
DEST_DIR="$PWD/local-apps" ./script/install.sh --no-open
```

The installer validates the staged bundle, preserves the existing app until
replacement succeeds, and restores it if replacement fails. This is an install
transaction rollback, not a general release downgrade mechanism. Back up or
export important presets before an upgrade.

The development bundle identifier is `com.local.TaskScope`. Moving to a future
owned production identifier changes the macOS preferences, permissions,
Shortcuts, URL-registration, and login-item identity. No automatic migration
should be assumed until a release explicitly documents and tests one.

To uninstall a local build:

1. Turn off **Keep GlobalProtect Off** on the GlobalProtect preset (or choose
   **Open**). This clears the persistent user and system launchd overrides; deleting
   TaskScope's preferences does not clear them. If the app is
   already gone, run `launchctl enable gui/$UID/com.paloaltonetworks.gp.pangpa`
   and `launchctl enable gui/$UID/com.paloaltonetworks.gp.pangps`, plus
   `sudo launchctl enable system/com.paloaltonetworks.gp.pangpsd`.
2. Turn off **Launch at Login** in TaskScope Settings.
3. Quit TaskScope and move `TaskScope.app` to the Trash.
4. Remove TaskScope from Accessibility and Notifications in System Settings if
   desired.
5. To erase current development-build preferences as well, run
   `defaults delete com.local.TaskScope`. This permanently removes local
   settings, presets, rules, saved selections, history, and corruption backups.

If stored data is reported as unreadable, preserve the named `.corruptBackup`
preference before using the corresponding destructive reset action. Presets can
be exported from Settings when their stored data is readable. See
[SUPPORT.md](SUPPORT.md) for recovery information.

## Features

- Search, filter, and sort processes by CPU, memory, name, or PID.
- Switch between flat and expandable process-tree views.
- Inspect process details, copy a command, or locate a process in Activity
  Monitor.
- Review immutable targets before sending Stop (`SIGTERM`) or explicit Force
  Stop (`SIGKILL`).
- Save selections using durable kernel executable-path matching, with legacy
  command/name fallback and preview recall results. A path-backed selection
  never downgrades to the legacy fallback.
- Create, edit, reorder, import, and export watched-app presets with optional
  user launch-agent jobs. Exports use a versioned archive; import accepts the
  legacy array format and shows a non-mutating field review before committing.
  A lifecycle dry run lists later Open/Close operations without performing
  them. Custom presets cannot configure privileged system launch daemons.
- Open or close watched apps through one lifecycle path with per-job reporting.
  Quit, Close, and Keep Off give a process 3 seconds to exit gracefully before
  force stopping it, and the confirmation dialog says so.
- Keep GlobalProtect off by persistently disabling its known user agents and,
  with explicit administrator approval, its system VPN service. Open restores
  the required services without reinstalling; session installations keep the
  separate system daemon disabled to avoid repeated administrator prompts.
  Login/reboot behavior still needs live validation.
  If automatic disconnect fails, **Stop Services Anyway…** offers a separately
  confirmed stop with a network-recovery explanation. The result window is
  brought forward after either success or failure.
- Create Prompt, Auto Stop, or Log Only runtime rules with event history. Auto
  Stop requires a trusted executable path; legacy name-only Auto Stop rules
  load disabled until reviewed.
- View sampled process CPU and RSS history with Live, Paused, and Unavailable
  states.
- Opt into watched-process notifications.
- Show TaskScope with a configurable global shortcut; the default is
  Command-Shift-T.
- Start nonintrusively at login or for automation.

Normal process actions never target TaskScope itself. Process targets are
revalidated against their captured identity immediately before a signal.

## URL automation safety contract

The packaged app registers the `taskscope` URL scheme. URLs can be opened by
another local app, document, or browser, so the public URL contract is
deliberately non-destructive:

```bash
open "taskscope://refresh"
```

- `taskscope://refresh` refreshes watched-app status.
- All other routes, including URL requests to open or stop a preset or quit the
  app, are rejected.
- A refresh received during cold launch is queued until the application command
  runtime is ready.

Destructive lifecycle actions require an in-app interaction or a user-configured
Shortcuts action. The only privileged lifecycle action is fixed restoration for
the immutable built-in GlobalProtect definition, and it requires in-app
administrator approval. Do not widen the URL contract without a new threat
review and regression tests.

## Shortcuts

After a properly signed packaged app is installed and launched, macOS Shortcuts
can discover:

- **Refresh TaskScope**
- **Open Watched App**
- **Stop Watched App**

Open and Stop use a watched-app entity selected by the user from TaskScope's
stored presets. They use the same lifecycle result reporting as the app, but a
Shortcuts **Stop Watched App** action runs without the in-app confirmation
dialog: configuring the shortcut is the confirmation. An ad-hoc signature is
insufficient for App Intents execution.

## Permissions and trust boundaries

- Activity Monitor integration requests Accessibility permission only when
  exact PID selection is requested. Denial does not prevent Activity Monitor
  from opening, and TaskScope reports the recovery path. TaskScope temporarily
  adjusts the search, process scope, or PID column only when needed and restores
  the prior Activity Monitor state after the handoff.
- GlobalProtect Quit All and explicit Keep Off also request Accessibility to
  verify and disconnect a running GlobalProtect client. They only press the fixed vendor app's
  Disconnect control; they do not enter credentials or answer policy challenges.
- Notifications are off on a new install and are requested only after opt-in.
- Launch at Login is optional and managed from Settings.
- Some process details and extended network/disk counters can be unavailable;
  TaskScope reports them as unavailable rather than fabricating zeroes.
- Auto Stop is destructive and path-bound. Use Prompt or Log Only while
  validating a rule.
- The immutable built-in GlobalProtect definition can request administrator
  approval to disable/unload or re-enable its fixed system daemon, and to load
  it when absent. Open never restarts a loaded daemon. Custom presets cannot define
  or alter privileged system-daemon jobs, and TaskScope does not bypass macOS
  authorization.
- Keep GlobalProtect Off changes user and system launchd overrides and can
  disconnect or prevent a required VPN session. TaskScope confirms the action,
  requests macOS authorization for the system change, and never applies it
  through a URL or a background privilege request.
- Imported presets are untrusted configuration. Importing must not execute a
  lifecycle action, but a later user-triggered action can use a custom preset's
  app path, user launch-agent labels and plist paths, and process names. Review
  those fields before acting. Imports cannot create custom privileged daemon
  behavior; the built-in GlobalProtect privileged definition is immutable.
- GlobalProtect service behavior is controlled by the installed product and the
  organization managing it. Use the organization/IT installer or support path
  if its protected service cannot be restored.

The maintained trust-boundary analysis is in [THREAT_MODEL.md](THREAT_MODEL.md).

## Privacy and security

TaskScope runs locally and contains no analytics or telemetry upload service.
It reads local process information and invokes local macOS tools. It does not
transmit process details to a TaskScope service.

Preferences can contain process names, PIDs, executable paths, preset paths and
job labels, rule configuration, saved selections, search text, and up to 200
auto-stop events. Process chart history is limited to 60 in-memory samples.
Process or preset names can also appear in local notifications and macOS Unified
Log error messages. Preset exports contain the configured lifecycle fields.

For support, use **Settings > Support > Preview Diagnostics** to review a
redacted report before copying or saving its exact JSON. It includes versions,
permissions, anonymous selected-preset identity, user launch-agent status, and
recent lifecycle failure categories. It excludes commands, usernames,
organization identifiers, process lists, raw errors, and preset paths. The
latest 20 lifecycle failures stay in memory until cleared or the app exits;
nothing is uploaded. See [the field-by-field export guide](SUPPORT.md#preview-and-export-support-diagnostics).

Read [PRIVACY.md](PRIVACY.md) for storage, retention, logging, deletion, and
permission details. Report suspected vulnerabilities according to
[SECURITY.md](SECURITY.md); never place sensitive process or organization data
in a public report.

## Distribution limitation

The 1.0.0 release is a source/development release. `script/build_and_run.sh` and
`script/install.sh` use the local bundle identifier `com.local.TaskScope`, build
the current Mac architecture, and create either an Apple Development-signed or
ad-hoc bundle. The locally verified scope is arm64. The output is not an owned
production identity, a universal binary, Developer ID-signed, or notarized.

Do not redistribute a local staged bundle as a production download. A future
public binary requires an owned identifier, explicit architecture policy,
hardened runtime and reviewed entitlements, Developer ID signing, Apple
notarization and stapling, checksums, and clean-machine verification.

The credential-gated `script/release.sh` pipeline automatically enforces a
non-development identifier format and arm64-only policy; verifies version,
build, deployment target, App Intents metadata, Developer ID team, hardened
runtime, and absence of entitlements; matches the app and dSYM UUIDs; submits
for notarization; staples and Gatekeeper-verifies the app; round-trips the final
ZIP; and emits provenance plus verified SHA-256 checksums. It cannot verify that
the identifier is actually owned, migrate existing preferences/permissions, or
perform clean-machine and cross-version QA. Those remain manual release gates.
The pipeline cannot complete without a real Developer ID identity, Apple Team
ID, and notary keychain profile. Its credential-independent preflight can be run
with a syntactically valid non-development candidate identifier:

```bash
TASKSCOPE_BUNDLE_ID=com.example.TaskScope ./script/release.sh --preflight
```

Preflight requires retained, candidate-specific GlobalProtect lifecycle evidence;
the current read-only observations intentionally fail that gate. Passing
preflight is not signing or notarization evidence. The evidence contract,
maintainer procedure, and claim rules are in [RELEASE.md](RELEASE.md).

## Project information

- [Support and recovery](SUPPORT.md)
- [Security policy](SECURITY.md)
- [Privacy](PRIVACY.md)
- [Roadmap](ROADMAP.md)
- [Contributing](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)

TaskScope is available under the [MIT License](LICENSE).

TaskScope is an independent project. GlobalProtect and Palo Alto Networks are
trademarks of their respective owners; this project is not affiliated with or
endorsed by Palo Alto Networks.
