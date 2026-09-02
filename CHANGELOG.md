# Changelog

All notable changes to TaskScope are documented in this file. The project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Added versioned preset archives with legacy import compatibility, bounded
  file reads, and a field-by-field, non-mutating import preview.
- Added stale process-inventory status with the last successful observation and
  a visible retry path.
- Added a confirmed, persistent Keep GlobalProtect Off control for the known
  per-user `pangpa` and optional `pangps` launch agents. Open explicitly clears
  the disable state; protected system daemons remain untouched.

### Changed

- Removed hosted GitHub Actions CI. The complete build, test, and packaging
  gate remains available locally; weekly Swift dependency updates remain enabled.

### Security

- Bound new automatic-stop rules and durable saved selections to
  kernel-resolved executable paths, and included that path in final pre-signal
  identity validation. Legacy name-only automatic stops load disabled for
  review.
- Made watched-app open/close actions fail closed when a fresh inventory cannot
  be read, without replacing failure with cached process state.
- Required Log Only outcomes to reach durable event storage before an
  occurrence is treated as handled.
- Normalized and rejected duplicate launch-job labels and plist paths across
  imported and persisted preset data.
- Migrated the built-in GlobalProtect definition to recognize both supported
  per-user agent layouts without accepting custom privileged fields.

### Fixed

- Open no longer requests administrator approval for a GlobalProtect daemon that
  launchd already has loaded, and never restarts a loaded daemon: readiness is
  verified from launchd's pid and a fresh process inventory instead of an
  unprivileged `lsof` port probe that could never succeed, and the privileged
  script only bootstraps a daemon that is not loaded.
- Keep GlobalProtect Off enforcement re-checks the persisted intent inside the
  operation gate and skips while a user action runs, so a poll tick can no
  longer re-disable the launch agents and quit the app right after Open.
- Open enables a kept-off user launch agent before bootstrapping it; launchd
  refuses to bootstrap a disabled job, so the previous post-bootstrap enable
  never took effect when it was needed.
- Open re-checks whether the restored launch agents already started
  GlobalProtect and no longer uses `open -n`, so it cannot launch a second
  instance.
- The Keep Off report sheet no longer appears on every launch; background
  enforcement publishes a report only when a launch-agent job fails.
- A process named PanGPS is reported as the protected system daemon only when it
  runs as root; the optional per-user `pangps` agent is shown separately as a
  user instance and never mistaken for the daemon.
- Quit Helpers leaves a launch agent loaded when it is the one running the main
  GlobalProtect process, and preset confirmations now name the launch agents
  that will be unloaded.
- The preset card's Open button addresses the clicked preset by identity, so a
  display name that matches another preset's main process name can no longer
  open the wrong preset.
- Importing a versioned preset archive with a malformed preset now reports the
  failing field instead of retrying the file as a legacy array and calling it
  unrecognized.
- Stop Now on an auto-stop prompt is authorized as a confirmed prompt (the
  rule must exist and be enabled) instead of being rejected by the
  automatic-stop rule and logged as failed.
- Editing an auto-stop rule's path, name, or runtime while its automatic stop
  is in flight cancels that stop; the final authority check compares the whole
  captured rule value.
- An accepted stop whose process has not exited yet is recorded as "Stop
  requested" and marked stopped once the process exits; automatic stops
  re-signal at most once before recording a single failure instead of sending
  SIGTERM on every tick.
- Preset Quit, Close, and Keep Off wait up to 3 seconds (polling every 250 ms)
  for a graceful exit before force stopping, and the confirmation dialog says
  so.
- Saving a selection now refuses an entry without a kernel executable path, and
  the recall preview marks legacy entries that can only match by name.
- launchd (pid 1), the kernel task, and process-group pids are dropped by the
  parser and refused by every signal path before `kill(2)`.
- A stop sent to a process that exited moments earlier is reported as stopped,
  not as a rejected signal, and a zombie is no longer counted as still running.
- Auto-stop rule paths resolve symlinks (for example a Homebrew link) so they
  match the kernel-reported executable path.
- A dismissed auto-stop prompt stays dismissed when its rule is toggled off and
  on.
- Auto-stop evaluations no longer overlap when a rule change restarts polling.
- Terminating a watched process always requires its executable directory; the
  name-only termination entry point was removed.
- Auto-stop events with an outcome written by another build keep that value
  instead of decoding as Logged.
- Recovery banners say when an unreadable payload could not be backed up
  because an earlier backup already occupies the slot.
- Removed a pipe-reader teardown race in command execution and strengthened
  cancellation near child exit.
- Preserved full executable paths in the process display schema and saved
  selection recall while keeping destructive matching on kernel paths.
- Drained cold-launch app commands in FIFO order.
- Avoided restarting an already-loaded user launch agent during ordinary Open.
- Coalesced recent observer inventory reads, suspended history when no metrics
  view is visible, and suspended auto-stop polling with no enabled rules.
- Restored Activity Monitor search, process scope, and PID-column state after a
  temporary exact-PID handoff.
- Tightened elapsed-runtime parsing, hotkey-handler error reporting, lifecycle
  report row identity, and icon-only accessibility labels.

## [1.0.0] - 2026-08-08

First source/development release. Build metadata is `1.0.0 (2)`. This release
does not include a Developer ID-signed, notarized, universal, or public binary.

### Added

- Native macOS process monitoring in flat and process-tree views.
- Watched-app presets with lifecycle controls and per-job result reporting.
- Graceful and forced process termination with target review and identity
  revalidation.
- Saved selections, auto-stop rules, notifications, and bounded process history.
- User-selected Shortcuts actions and a refresh-only URL automation route.
- Source builds, transactional local installation, and packaging verification.
- Maintainer release, rollback, privacy, support, threat-model, and roadmap
  documentation.

### Security

- Restricted untrusted custom-URL automation to the non-destructive refresh
  action; preset open/stop and application quit URLs are rejected.
- Hardened lifecycle configuration validation and shell argument boundaries for
  local launch-job operations.
- Preserved process identity across confirmations and asynchronous work so an
  action cannot silently move to a recycled PID or a different queued prompt.
- Preserved unreadable preference payloads and required explicit reset rather
  than overwriting them with fallback data.

### Fixed

- Report process-inventory and lifecycle failures without claiming that a stop
  succeeded or that a target disappeared when it could not be verified.
- Treat an already-missing launch-agent plist as absent during unload while
  continuing to report it as blocking when restoration requires it.
- Preserve AppleScript newlines in administrator-approved daemon restoration.
- Give the built-in GlobalProtect preset a stable identity so Shortcuts survive
  relaunches.
- Re-baseline watched-process notifications when preset process names or
  notification settings change, avoiding false "started" notifications.
- Re-check auto-stop rules after suspension points and retry actions that were
  never attempted.
- Prevent extended process metrics collection from remaining active after its
  final consumer exits.
- Keep corrupt preset, rule, event, settings, and saved-selection backups from
  being clobbered by later reads.

[Unreleased]: https://github.com/38st/TaskScope/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/38st/TaskScope/releases/tag/v1.0.0
