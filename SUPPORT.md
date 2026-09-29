# Support and Recovery

TaskScope is currently distributed as source with local-development packaging.
There is no guaranteed support response time and no published production binary
support channel.

## Before requesting help

Record:

- the exact version and build from About TaskScope;
- macOS version and Mac architecture;
- whether the app was source-built, ad-hoc signed, Apple Development-signed, or
  obtained from a published release;
- the failing action and its exact user-visible result;
- whether notification, Accessibility, login-item, or built-in GlobalProtect
  administrator approval was denied.

Sanitize all logs and screenshots. Process names, commands, usernames, app and
plist paths, job labels, ports, and organization details can be sensitive.

Use a GitHub bug report for a reproducible non-security defect. Do not use a
public issue for a vulnerability or private conduct report; follow
[SECURITY.md](SECURITY.md) and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Preview and export support diagnostics

Open **Settings > Support**, choose the preset involved in the failure, and
choose **Preview Diagnostics**. Choose **No preset** for app and permission
information only. The preset picker shows local display names so you can choose
the right entry; those names are not part of the report. A screenshot of the
picker or an ordinary lifecycle report can still expose private information.

The preview shows the complete, read-only JSON snapshot. **Copy JSON** copies
that exact text to the clipboard. **Save JSON…** asks for a destination and writes
one UTF-8 file, named `TaskScope-diagnostics.json` by default, containing exactly
the preview bytes. There are no extra files, logs, hidden fields, or attachments.
Canceling the save dialog writes nothing. **Done** closes the preview without
exporting. Close and generate another preview to refresh its contents; changes
to permissions, presets, or lifecycle history never silently change an open
preview. TaskScope does not send the report anywhere. Share it yourself only
after reviewing it.

Schema version 1 includes exactly these fields:

| Field | What you can review and export |
| --- | --- |
| `schemaVersion`, `app` | Report format version and the fixed name `TaskScope`. |
| `version`, `build` | Numeric app version/build from the app bundle, or `unavailable` for absent or nonnumeric metadata. No bundle identifier, signing identity, team identifier, or toolchain paths. |
| `macOS`, `architecture` | Numeric macOS major/minor/patch version and the architecture of the running TaskScope binary (`arm64`, `x86_64`, or `unknown`), which can differ from hardware under translation. |
| `capturedAt` | UTC timestamp when collection completed. Status reads occur over the collection interval, not as an atomic system snapshot. |
| `permissions` | Notification authorization (`unknown`, `notRequested`, `denied`, `allowed`, or `provisional`), the app notification toggle, Accessibility granted boolean, and Launch at Login (`off`, `on`, `requiresApproval`, or `unavailable`). Administrator authorization explicitly says `not queried; requested per privileged action`; it is not a persistent grant or a claim that approval was given. |
| `selectedPreset` | Omitted when no preset is chosen. Otherwise: the report-local reference `selected-preset`, kind (`builtInGlobalProtect` or `custom`), app-bundle found boolean, Keep Off requested boolean, and the user launch-agent entries below. Custom preset names and saved UUIDs are omitted; the reference has meaning only within this report. |
| `selectedPreset.userLaunchAgents` | Each configured user agent's one-based number in preset order, required boolean, plist-found boolean, and current state (`loaded`, `notLoaded`, or `unknown`). An empty array means no user agents are configured. No labels or paths are included. |
| `recentLifecycleFailures` | Newest first, only for the selected preset: UTC event time, action (`open`, `quitApp`, `quitHelpers`, `close`, `keepOff`, or `allowToRun`), background-enforcement boolean, fixed reason category, failed-job count, and missing-job count. An empty array means no retained failures for that selection. |

Failure reasons are `appBundleMissing`, `inventoryUnavailable`,
`systemServiceFailed`, `userLaunchAgentFailed`, `launchFailed`, `signalRejected`,
`verificationUnavailable`, `stillRunning`, or the fallback `incomplete`.
Counts refer to job results in that action attempt; an early failure can have
zero job failures. They do not contain job labels or raw error details, and
cannot identify a particular organization's managed-service policy.

Collection reads notification, Accessibility, and login-item state without
requesting permission. It checks configured file existence and reads the
selected preset's user launch-agent load status without changing any jobs,
opening apps, signaling processes, requesting administrator access, or reading
the process inventory or logs. Failed, canceled, and timed-out status reads
remain `unknown`. A false file-found value can also mean the path is inaccessible.
Loaded does not guarantee a process is healthy. Keep Off reports TaskScope's
saved intent, not verification of launchd's persistent disable override. No
protected system-daemon inspection is performed by diagnostics.

The session history retains the latest **20 failed lifecycle actions across all
presets**, then filters to the selected preset for export. It includes actions
executed through the UI and automation, and marks background Keep Off
enforcement. Successful actions, skipped enforcement, individual process stops,
auto-stop event history, and failures from earlier app sessions are excluded.
New entries evict the oldest. **Clear Failure History** or quitting TaskScope
clears this in-memory history. Clearing history does not change an existing
preview, clipboard content, or saved file. Delete saved reports yourself and
replace clipboard contents if you want to remove those copies.

There is no unredacted diagnostics mode. Usernames, commands, organization
identifiers, process names/PIDs/full process lists, preset names/UUIDs, app/plist
paths, launch-job labels, raw errors, Unified Logs, preference payloads, and
corruption backups are excluded. Ordinary **Watched Apps > Export** is a separate
preset backup feature and includes configured names and paths; it is not a
privacy-safe support report.

## Permission and installation health

Open **Settings > Health** for one local view of notifications, Accessibility,
Launch at Login, code signing, App Intents/Shortcuts, every saved preset's app
and launch-plist paths, and the running app's bundle identity. **Refresh Health**
repeats the read-only checks. The view also refreshes on opening and when
TaskScope becomes active, including after a visit to System Settings. Changes
to presets or the app notification preference trigger another collection.

Results show when collection began. They become **Stale** after one minute,
when TaskScope becomes inactive, or while a newer collection is pending.
Observations occur over the collection interval, not atomically. A late or
canceled collection cannot overwrite a newer result. Refresh remains available
for every failed or unverified result; it never requests permission.

| State | Meaning and next step |
| --- | --- |
| Verified | The described local check passed. Read its scope: notification authorization does not guarantee delivery, a login registration does not prove login execution, and signature integrity does not establish notarization or Gatekeeper acceptance. |
| Off / Not requested / Requires approval | Respectively, login registration is off, notification authorization has not been requested, or macOS requires login-item approval. These are distinct from denial. |
| Denied | macOS explicitly denies notification authorization. Review Notifications in System Settings. |
| Unavailable | A required service, readable file, metadata artifact, or supported signing mode is unavailable. An unreadable path is not reported as missing. A bare SwiftPM executable cannot provide bundled notification/login-item checks. |
| Stale | The observation expired, a configured required path is missing, or the on-disk app no longer matches the running instance. Refresh; review the relevant preset or installation before a manual relaunch. |
| Unverified | Evidence is incomplete or cannot establish readiness. Accessibility's false trust value cannot distinguish denial from never-requested access; the view says access is not granted without inventing that distinction. Login-item `notFound` alone does not prove a stale registration. |

Recovery buttons only navigate: **Open System Settings** opens a verified local
System Settings app (follow the pane directions in the row), **Reveal App
Location** asks Finder to show the verified existing bundle location, and
**Review Watched Apps** selects that Settings tab. Unavailable destinations are
omitted. Targets and result freshness are rechecked on click; opening failures
are reported and never treated as a repair. Finder has no completion callback,
so TaskScope reports a navigation request rather than confirmed presentation.
Closing the destination reverses this navigation. Refresh if a target changes.

The health view never resets TCC, registers/unregisters login items, toggles a
permission, edits presets, deletes/moves apps, re-signs or reinstalls software,
loads/unloads jobs, or runs a Shortcut. Use the existing explicit controls or
the source packaging instructions below after reviewing the finding.

Signature checks validate local sealed content with network access disabled;
they do not query signing identities in the keychain. Intact ad-hoc signing is
reported as an App Intents blocker. Even a valid non-ad-hoc signature plus the
expected metadata remains **Unverified** for actual Shortcuts discovery and
execution. Bundle identity accepts valid custom identifiers and compares the
running code with disk; it does not scan for duplicate app copies or promise
permission continuity after replacement. A detected replacement marks the
permission/login and App Intents findings stale until a new running instance
can be checked.

Preset checks read app metadata/executable presence and configured plist labels,
including the fixed built-in system plist. They never inspect arbitrary system
jobs. Missing optional user-agent plists are explicitly acceptable; missing
required paths are stale. Malformed files, mismatched labels, non-executable
apps, and unsupported/oversized metadata are unverified. A corrupt preset store
is unverified rather than approving its fallback list. Findings number presets
and plists in saved order without displaying their raw names, paths, or labels.

Health findings remain in memory. They are not added to the frozen, schema-1
Support JSON report described above. Automated tests cover simulated revocation,
replacement, expiry/cancellation, destination failure, metadata validation, and
real temporary path fixtures. Live permission revocation, signed-app replacement,
login/reboot, and Shortcuts execution still require manual testing on each
supported macOS/signing combination; automated evidence does not certify them.

## Common recovery steps

### App will not start or Shortcuts cannot discover actions

1. Run `./script/build_and_run.sh --stage` and then
   `./script/build_and_run.sh --verify` from the source checkout. `--verify`
   checks the bundle that is already staged and does not rebuild it.
2. Verify the installed app, not the bare SwiftPM executable, is being launched.
3. An ad-hoc signature cannot execute TaskScope App Intents. Rebuild with an
   eligible Apple Development identity for local Shortcuts testing.
4. Reinstall using `./script/install.sh`, launch once, and retry Shortcuts.

These steps do not make the app Developer ID-signed or notarized.

### Process information is unavailable

TaskScope relies on local macOS process tools. Retry after refreshing. If the
inventory remains unavailable, record the exact in-app error rather than
assuming that no process is running. Extended network/disk counters can be
unavailable independently of the basic process list.

### Activity Monitor opens but does not select the PID

Allow TaskScope in **System Settings > Privacy & Security > Accessibility**, then
retry. If access is intentionally denied, Activity Monitor can still open but
exact selection is unavailable. When exact selection temporarily changes the
Activity Monitor search, process scope, or PID column, TaskScope restores the
prior state after a short handoff delay.

### Notifications do not appear

Enable notifications inside TaskScope and allow TaskScope in macOS Notification
settings. If access was denied or revoked, use the Settings recovery link and
retry only after macOS reports permission as allowed. Enabling a watched preset
does not imply global notification authorization.

### Launch at Login needs approval

Open TaskScope Settings, inspect its login-item status, and follow the macOS
Login Items recovery link. Disable and re-enable only after the current state is
visible. During uninstall, disable Launch at Login before deleting the app.

### Stored data is unreadable

TaskScope preserves unreadable payloads under a preference key ending in
`.corruptBackup` and prevents some affected stores from overwriting the primary
data. Preserve the named backup before selecting a destructive reset. Do not
export an empty fallback list as a backup. Reset resumes persistence with the
currently recovered in-memory state where supported.

Legacy name-only Auto Stop rules are retained but disabled. Add and verify the
intended absolute executable path before enabling automatic stopping.

### A watched-app lifecycle partially fails

Read the per-job lifecycle report. Missing app/plist paths and user launch-agent
failures apply to custom presets. Administrator denial and managed-service
policy apply only to the immutable built-in GlobalProtect system-service
path. Do not repeat that privileged operation blindly; use the organization's
managed installer or IT support when its protected service cannot be restored.

### GlobalProtect keeps reopening

**Quit All** from the menu bar opens the regular TaskScope window so the
disconnect/stop progress and final result remain visible when GlobalProtect's
menu takes focus. The Presets footer wraps long failure messages. A vendor
**Connection Failed** view can be stopped once TaskScope verifies its enabled
Connect control and absence of Disconnect for consecutive observations; an
unknown Error state still leaves services running and explains the failure.

Use **Keep GlobalProtect Off** on the built-in preset. Confirm the action and
approve the macOS administrator dialog if the system service still needs to be
disabled/unloaded. This disconnects any VPN. Choose **Open** to restore the
required services without reinstalling. Turning Keep Off off now performs the
same restoration, starting the VPN service and app together.

If GlobalProtect is stuck retrieving portal configuration after being opened
directly, choose **Open** in TaskScope. When the UI is running without PanGPS,
TaskScope closes that orphaned UI and restores the service before starting one
new instance. An existing healthy VPN service is left running. Open also avoids
loading another UI agent over an app instance opened outside launchd.

When the installed `pangps` session agent supplies the VPN service, Open and
toggle-off retain the separate system daemon's disabled override. After the
first full stop, subsequent Open/Keep Off cycles therefore need no password.
No password is stored and no elevated helper or authorization-policy exception
is installed. Layouts without that session agent still require administrator
approval to restore the system daemon. An unreadable or mismatched session
agent label is reported as a failure, not as successful restoration.

If approval is cancelled or a service remains loaded, the result reports a
failure. **Apply Keep Off…** retries the explicit stop. Existing Keep Off
preferences from older builds require this explicit action to stop the system
service. Background enforcement never requests administrator privileges.

A `PanGPS` process running as root can belong to either the login-session
`pangps` job or the system `pangpsd` job. Open restores and verifies the installed
session service first; the system daemon is used when that agent is absent.
Ordinary Quit actions unload session jobs but leave the system daemon alone.
An off result verifies the known processes and launchd jobs, not VPN health or
system extension removal. If policy restores or rejects changes to services,
consult the organization managing the Mac.

Quit All and explicit Keep Off press Disconnect automatically and wait for a
stable idle state so the VPN can restore normal networking. Earlier live tests
on 6.3.3-1121 found public DNS unavailable after stopping
following VPN use, including one stop after the client showed Disconnected.
Open restored DNS without reconnecting the VPN; stopping that idle service
retained public DNS/HTTPS access. If DNS fails, choose Open, leave the VPN
disconnected, verify normal internet access, and retry Keep Off. TaskScope does
not rewrite DNS, routes, or vendor settings as a workaround.

### Collect GlobalProtect compatibility evidence

Choose **Compatibility Self-Check** under **Keep GlobalProtect Off** on the
built-in preset, or in **Settings > Watched Apps > GlobalProtect**. The check
runs when opened; **Refresh** collects a new observation. It does not toggle
Keep Off, write preferences, signal processes, load/unload jobs, start the VPN,
or request administrator approval. Normal TaskScope monitoring and any already
enabled Keep Off enforcement continue independently.

The preview includes the capture time, macOS version/build, TaskScope
version/build and process architecture, installed GlobalProtect bundle
version/build, and Keep Off intent. Bare SwiftPM/test executables have no
TaskScope bundle version; record the source revision separately in that case.
For each known `pangpa`, optional `pangps`, and protected system `pangpsd` job,
it shows plist presence/label validation, the launchd disabled override, and
loaded state. Missing files do not imply unloaded jobs or cleared overrides.
**No override** means the plist default applies; it does not mean explicitly
enabled. Read failures, timeouts, and unknown formats remain unknown.

Process counts distinguish the current user, root, other users, and unverified
identity/owner. A name-only match is unverified. The protected service process
is verified only when a root `PanGPS` with a kernel executable path in a known
product directory matches the system job's launchd PID. Loaded is different
from running, and neither proves VPN connectivity or policy compatibility.
Additional/relocated jobs are outside the fixed preset's detection scope.

Review the preview, then choose **Copy Summary** or **Export…**. Both share
exactly that text; export creates a UTF-8 `.txt` file at your chosen location.
The summary omits usernames, numeric UIDs/PIDs, hostnames, executable/home
paths, arguments, unrelated labels, raw command output, and organization/VPN
configuration. It retains the public GlobalProtect job labels and versions
needed to compare installations. Nothing is uploaded automatically. Delete
saved files when no longer needed and replace clipboard contents after sharing.

For a compatibility report, attach the redacted text with the failing action,
expected/actual result, source revision or release, and installation/signing
method. For an authorized managed test machine, collect separate before/after
reports for Keep Off, TaskScope relaunch, login/reboot, and Open/restoration.
Record which actions were actually tested and whether management restored an
agent. Do not publish organization names or VPN addresses. Follow the evidence
matrix and limits in [GLOBALPROTECT_COMPATIBILITY.md](GLOBALPROTECT_COMPATIBILITY.md);
a read-only observation alone is not a successful lifecycle test.

## Export and upgrade precautions

Export readable watched presets before a risky upgrade. The current development
bundle identifier is `com.local.TaskScope`; changing to a production identifier
changes the preferences, permissions, Shortcuts, URL, and login-item identity.
Do not assume local development state migrates until the release explicitly says
that migration was tested.

## Uninstall and erase local data

1. Turn off **Keep GlobalProtect Off** (or choose **Open**). The control writes
   persistent user and system launchd overrides that `defaults delete` does not
   clear. If TaskScope is already gone, clear it manually:

   ```bash
   launchctl enable gui/$UID/com.paloaltonetworks.gp.pangpa
   launchctl enable gui/$UID/com.paloaltonetworks.gp.pangps
   sudo launchctl enable system/com.paloaltonetworks.gp.pangpsd
   ```

2. Turn off Launch at Login.
3. Quit TaskScope.
4. Delete the app bundle.
5. Remove Accessibility and notification permission entries if desired.
6. For the current development identifier only, erase preferences with:

   ```bash
   defaults delete com.local.TaskScope
   ```

The final step is permanent and removes settings, presets, rules, saved
selections, event history, and corruption backups. A production release with a
different identifier requires its own documented deletion command.
