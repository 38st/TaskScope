# Privacy

TaskScope is a local macOS utility. It has no TaskScope account, analytics
service, advertising SDK, telemetry upload, cloud synchronization, or automatic
diagnostic upload. It does not transmit process information to a TaskScope
service.

This policy describes the source/development release. If a future updater,
website integration, crash reporter, or other network feature is added, this
document and the in-app disclosure must be updated before that feature ships.

## Data TaskScope reads

TaskScope can read local information exposed by macOS process tools, including:

- PID, parent PID, process owner UID, process/executable name, command path,
  start and elapsed time;
- observed CPU and resident memory usage;
- extended per-process network byte counters (from `nettop`) and cumulative
  disk I/O byte counters (from the kernel's per-process resource usage) when
  available;
- configured application and launch-job status;
- macOS notification, Accessibility, and login-item authorization state.

Some values can be unavailable because of macOS permissions or tool behavior.
TaskScope should represent them as unavailable rather than inventing a value.

**Settings > Health** additionally reads local app-bundle metadata, bounded App
Intents metadata, code-signature integrity and running/on-disk code identity,
and configured preset app/executable/plist presence and plist labels. Signature
validation explicitly disables network access and does not enumerate keychain
signing identities. Destination checks locate System Settings and Finder for
optional navigation. The check does not request permissions, change login
registration, run Shortcuts, or modify files, preferences, or launch jobs.

Health observations are kept only in memory, are refreshed on demand and when
the visible view becomes active, and expire after one minute or app inactivity.
They display fixed explanations and numbered preset/plist references rather
than raw paths, labels, signing certificates, or team identifiers. They are not
persisted, copied, uploaded, or included in the separate Support JSON export.
Recovery buttons only open verified local destinations or select Watched Apps;
they do not automatically repair or reset permissions or installation state.

## Data stored on the Mac

TaskScope uses standard macOS preferences for:

- refresh, display, search, sorting, threshold, notification, and the explicit
  Keep GlobalProtect Off preference;
- watched-app presets, including app paths, user launch-agent plist paths and
  labels, process names, and notification choices; the immutable built-in
  GlobalProtect definition also contains its fixed protected-daemon fields;
- saved selections, including process names, executable/command paths, and the
  PID captured when saved;
- auto-stop rules, including an optional executable path (required for enabled
  automatic stopping), and up to 200 recent event records, which can include
  process name, PID, time, outcome, and result detail;
- global hotkey and onboarding state;
- preserved `.corruptBackup` payloads created when stored data cannot be read.

Preferences are not encrypted by TaskScope. Other software running with the
same user's access may be able to read or modify them.

The process-history chart keeps at most 60 samples in memory and does not
persist them. Pending prompts and current process inventory are also transient.
Support diagnostics keep at most 20 recent failed lifecycle actions in memory
across all presets. Entries contain only a local preset UUID for filtering,
time, action/reason categories, a background-enforcement flag, and failed/missing
job counts. Raw job labels and error text are discarded at capture. This
history disappears on app exit or when cleared in Settings > Support.

## Exports, notifications, and logs

**Settings > Support > Preview Diagnostics** creates a local, redacted JSON
preview. Only an explicit **Copy JSON** or **Save JSON…** exports its contents;
both use the exact frozen preview. The report contains TaskScope version/build,
numeric macOS version and binary architecture, UTC collection/event timestamps,
permission/login-item status, anonymous selected-preset identity, file-found
booleans, configured user launch-agent status, and recent lifecycle failure
categories/counts for that preset. The canonical built-in preset is identified
as GlobalProtect; custom display names and saved preset UUIDs are excluded.

Diagnostics exclude usernames, commands, organization identifiers, process
lists/names/PIDs, raw preset paths, job labels, raw errors, logs, signing/team
identifiers, preferences, and corruption backups. They do not request
permissions, run lifecycle actions, or upload anything. The picker itself shows
local preset names, so screenshots of it are not redacted. See
[SUPPORT.md](SUPPORT.md#preview-and-export-support-diagnostics) for the exact
field inventory, status limitations, export behavior, and deletion steps.

The GlobalProtect Compatibility Self-Check reads only the known product plists
and version metadata, launchd status, macOS versions, and a fresh basic process
inventory. It does not read VPN configuration or collect extended network/disk
metrics. Its preview, clipboard copy, and text export contain the same selected
fields: capture time, versions/process architecture, Keep Off intent, public
job labels and state, process counts by owner category, and protected-service
verification. Raw output, usernames, numeric UIDs/PIDs, hostnames, executable
paths, arguments, unrelated jobs, and organization/VPN configuration are
omitted. Unexpected metadata is replaced with an unavailable/redacted state.
The report remains in memory until the sheet closes; copying uses the system
clipboard, and exporting writes only to a user-selected destination. Nothing
is uploaded. Delete saved summaries and replace clipboard contents to remove
those copies; TaskScope does not manage their later retention or sharing.

A preset export is created only after the user chooses a destination. It
contains configured preset fields and can reveal organization-specific app
paths, user launch-agent labels and paths, or process names. The immutable
built-in GlobalProtect entry also contains its fixed service fields. Inspect and
sanitize an export before sharing.

When notifications are enabled, process names can appear in Notification
Center. TaskScope also writes local macOS Unified Log errors. A failed automation
or lifecycle message can include a preset or process name. The
`build_and_run.sh --logs` and `--telemetry` modes display local Unified Logs;
`--telemetry` does not upload them.

Never attach an unsanitized process list, command line, preset export, log, or
screenshot to a public issue.

## Permissions

- **Notifications:** requested only after the user opts in. macOS controls
  delivery and stores displayed notifications.
- **Accessibility:** requested for exact PID selection in Activity Monitor.
  TaskScope does not need it for ordinary process monitoring. When selection
  requires a temporary search, process-scope, or PID-column change, TaskScope
  restores the prior Activity Monitor state after the handoff delay.
- **Administrator authorization:** requested to stop, re-enable, or restore the fixed system
  daemon in the immutable built-in GlobalProtect definition. Custom presets
  cannot add privileged daemon jobs, and TaskScope does not store the password.
- **Launch at Login:** optional and controlled in TaskScope Settings and macOS
  Login Items.

Keep GlobalProtect Off stores launchd disable overrides for the fixed user-agent
labels and, after explicit administrator approval, the fixed system VPN service.
Turning it off clears those overrides without starting anything. Open clears
them before restoring the services. Background enforcement never requests
administrator authorization. No new preferences, credentials, network data, or
export fields are introduced by system service control.

Revoking a permission in System Settings can limit the related feature without
deleting TaskScope's preferences.

## Retention and deletion

- Auto-stop events retain the newest 200 records.
- Process chart history retains the newest 60 in-memory samples and disappears
  when the app exits.
- Other preferences remain until changed, reset, or deleted by the user.
- Corruption backups remain until the preferences domain is removed or they are
  deliberately deleted during recovery.
- Preset export files remain wherever the user saved them.
- Support diagnostics history retains the latest 20 failures in memory until
  cleared in Settings > Support or the app exits. Saved diagnostics files and
  clipboard copies remain under the user's control; clearing history does not
  erase them or alter an already-open preview.
- The Keep GlobalProtect Off launchd override lives in launchd's user and system
  databases, not in TaskScope's preferences. It remains until the control is
  turned off, Open is chosen, or it is cleared manually with
  `launchctl enable gui/$UID/com.paloaltonetworks.gp.pangpa` and
  `launchctl enable gui/$UID/com.paloaltonetworks.gp.pangps`, plus
  `sudo launchctl enable system/com.paloaltonetworks.gp.pangpsd`.

To remove the current development build and its stored data:

1. Turn off Keep GlobalProtect Off (or choose Open) so the launchd override is
   cleared; `defaults delete` does not clear it.
2. Disable Launch at Login.
3. Quit and delete the app.
4. Run:

```bash
defaults delete com.local.TaskScope
```

This is destructive and also removes corruption backups. A future production
bundle identifier will use a different preference domain; follow that release's
uninstall instructions instead of assuming this command applies.

## Network behavior

TaskScope invokes local macOS tools such as `ps`, `nettop`, `launchctl`, and
`open`. Reading local per-process network counters with `nettop` is not a
network transmission by TaskScope. The current app source contains no TaskScope
network service or update check.

SwiftPM and developer tooling can access dependency hosts while building; that
is build-tool behavior, not runtime app telemetry.

## Security and questions

See [THREAT_MODEL.md](THREAT_MODEL.md) for trust boundaries,
[SECURITY.md](SECURITY.md) for vulnerability reporting, and
[SUPPORT.md](SUPPORT.md) for recovery guidance.
