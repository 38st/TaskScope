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

- PID, parent PID, process/executable name, command path, start and elapsed time;
- observed CPU and resident memory usage;
- extended per-process network byte counters (from `nettop`) and cumulative
  disk I/O byte counters (from the kernel's per-process resource usage) when
  available;
- configured application and launch-job status;
- macOS notification, Accessibility, and login-item authorization state.

Some values can be unavailable because of macOS permissions or tool behavior.
TaskScope should represent them as unavailable rather than inventing a value.

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

## Exports, notifications, and logs

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
- **Administrator authorization:** requested only to restore the fixed protected
  daemon in the immutable built-in GlobalProtect definition. Custom presets
  cannot add privileged daemon jobs, and TaskScope does not store the password.
- **Launch at Login:** optional and controlled in TaskScope Settings and macOS
  Login Items.

Keep GlobalProtect Off also stores a per-user launchd disable override for the
known GlobalProtect user launch-agent labels. Turning the control off clears
those overrides without starting anything, and Open always clears them before
it loads the agents. TaskScope does not use this control on a protected system
launch daemon.

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
- The Keep GlobalProtect Off launchd override lives in launchd's per-user
  database, not in TaskScope's preferences. It remains until the control is
  turned off, Open is chosen, or it is cleared manually with
  `launchctl enable gui/$UID/com.paloaltonetworks.gp.pangpa` and
  `launchctl enable gui/$UID/com.paloaltonetworks.gp.pangps`.

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
