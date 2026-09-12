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
policy apply only to the immutable built-in GlobalProtect daemon-restoration
path. Do not repeat that privileged operation blindly; use the organization's
managed installer or IT support when its protected service cannot be restored.

### GlobalProtect keeps reopening

Use **Keep GlobalProtect Off** on the built-in preset instead of repeatedly
killing its window. The control disables and unloads the known per-user
`pangpa` and, when installed, `pangps` launch agents. It persists across login.
Choosing **Open** or turning the control off re-enables those user agents.

The per-user `pangps` agent runs a process that is also named `PanGPS`. The
protected system `PanGPS` launch daemon (the one running as root) remains
outside this control and is never unloaded, signalled, or restarted; TaskScope
shows a per-user instance separately as "PanGPS (user)" so it is not mistaken
for the daemon. If policy or management software restores user agents, consult
the organization managing the Mac.

## Export and upgrade precautions

Export readable watched presets before a risky upgrade. The current development
bundle identifier is `com.local.TaskScope`; changing to a production identifier
changes the preferences, permissions, Shortcuts, URL, and login-item identity.
Do not assume local development state migrates until the release explicitly says
that migration was tested.

## Uninstall and erase local data

1. Turn off **Keep GlobalProtect Off** (or choose **Open**). The control writes
   a persistent per-user launchd override that `defaults delete` does not
   clear. If TaskScope is already gone, clear it manually:

   ```bash
   launchctl enable gui/$UID/com.paloaltonetworks.gp.pangpa
   launchctl enable gui/$UID/com.paloaltonetworks.gp.pangps
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
