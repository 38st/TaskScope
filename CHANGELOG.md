# Changelog

All notable changes to TaskScope are documented in this file. The project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Extended explicit Keep GlobalProtect Off to disable and unload the fixed system
  VPN service with macOS administrator approval. Open re-enables and restores
  services without reinstalling; toggle-off only clears persistent overrides.
  Background enforcement never requests privileges. Partial failures and a
  still-running system service are visible, with an explicit retry action.
  Automated regression coverage is separate from unverified live VPN and
  login/reboot compatibility.

- Added Settings > Health to aggregate notification, Accessibility, login-item,
  code-signing/App Intents, preset-path, and bundle-identity diagnostics. Denied,
  unavailable, stale, and unverified results stay distinct; observations expire
  and refresh after activation. Recovery offers only verified reversible
  navigation and refresh, with no permission resets or installation changes.
  Focused tests cover revocation/replacement simulations, path and metadata
  failures, stale collections, and recovery checks. Support/privacy guidance
  documents local-only retention and the limits of signing/Shortcuts evidence.

- Added previewable support diagnostics in Settings with exact JSON copy/save,
  anonymous preset references, permission and user launch-agent status, and a
  bounded session history of redacted lifecycle failures. Redaction tests and
  the support/privacy guides specify every exported field and deletion behavior.

- Added a read-only GlobalProtect Compatibility Self-Check with known optional
  agent installation/label checks, launchd disabled and loaded states,
  ownership-aware process counts, protected system-service verification, and
  macOS/TaskScope/GlobalProtect versions. Preview, clipboard, and text export
  share one redacted summary. Focused tests and a compatibility evidence matrix
  distinguish simulations and live observations from lifecycle validation.
- Added versioned preset archives with legacy import compatibility, bounded
  file reads, and a field-by-field, non-mutating import preview.
- Added stale process-inventory status with the last successful observation and
  a visible retry path.
- Added a confirmed, persistent Keep GlobalProtect Off control for the known
  per-user `pangpa` and optional `pangps` launch agents. Open explicitly clears
  the user-agent disable state; system-service control is described above.

### Changed

- Changed the default global shortcut to Control-Option-Command-T (⌃⌥⌘T).
  Existing saved shortcuts, including Command-Shift-T, remain unchanged and
  can still be recorded explicitly.
- Preserve delivered automatic-stop outcomes when a rule is edited, disabled,
  or deleted in flight, without retaining retries for the retired rule.
- Preserve unknown top-level settings and newer schema versions on save after
  a downgrade; unreadable-payload recovery remains unchanged.
- Bound GlobalProtect disconnect observations and Accessibility requests by a
  shared 90-second deadline. Timeout leaves services running.
- Show the quick auto-stop rule's executable path or name-wide scope live,
  including an explanation when Auto Stop lacks a required path.
- Read launch-job PIDs only from the top level of complete launchctl output;
  nested child PIDs cannot establish service readiness.

- Avoid repeated administrator prompts on GlobalProtect session-agent
  installations. Open and toggle-off retain the unused system daemon's disable
  override while restoring the required user jobs. Once the first full stop is
  approved, later Open/Keep Off cycles require no system mutation. System-only
  layouts keep the administrator path; malformed session plists fail visibly.

- Fixed process identity validation for macOS `ps` timestamps padded with spaces
  or tabs. Valid processes no longer disappear from the inventory or produce a
  false Quiet state; incomplete reads must include TaskScope's own stable PID.
  Regression coverage includes the live process inventory.

- Fixed GlobalProtect restoration on installations where the login-session
  `pangps` job runs PanGPS as root. Open now restores and verifies that installed
  job instead of waiting for the separate system daemon, which can remove
  itself when pre-logon is disabled. User-job bootstrap no longer force-restarts
  the process it just launched. Stop waits for launchd to finish removing an
  acknowledged job instead of reporting a premature failure during shutdown.
  Regression tests cover root/current-user session
  services and mismatched PID, owner, or executable.
- Added Disconnect-first guidance and Open recovery instructions after live
  testing found stale VPN DNS after stopping, even following a disconnect.
  Open restored normal DNS; stopping that idle service preserved DNS/HTTPS.

- Separated process-list projection and caching from process operations, and
  consolidated preset stop coordination while preserving target selection,
  failure precedence, diagnostics, and user-facing messages.
- Normalize launch-job values without reconstructing them, preserving optional
  job flags and other metadata as the model evolves.
- Public-binary preflight and release now require versioned GlobalProtect
  lifecycle evidence tied to the tested candidate, passing results for every
  lifecycle/protected-service/VPN/policy check, and retained reports. Missing,
  failed, or stale coverage blocks release with collection instructions;
  isolated packaging regressions cover acceptance and rejection. Existing
  read-only observations remain unverified for lifecycle compatibility.
- Removed hosted GitHub Actions CI. The complete build, test, and packaging
  gate remains available locally; weekly Swift dependency updates remain enabled.
- Bumped the build number to 3. `script/release.sh` now refuses a build number
  that is not greater than the latest `v*` tag's and a release whose version
  has no changelog heading.
- `script/build_and_run.sh --verify` verifies the bundle that is already
  staged instead of rebuilding and restaging it first.
- The app icon is rendered into explicit bitmaps so the `.icns` carries every
  member (16 through 512 points at 1x and 2x) at its exact pixel size, and
  bundle verification checks the full member set.
- The uninstall instructions start with turning off Keep GlobalProtect Off,
  because the launchd override it writes is not removed by `defaults delete`;
  the manual `launchctl enable` recovery commands are documented.
- Documented that Shortcuts stop actions run without the in-app confirmation
  dialog, that Keep Off unloads the per-user `pangps` agent while the root
  system daemon is untouched, and that the bug report template no longer offers
  a nonexistent release download as an install source.

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

- Short-lived shell commands are reaped after exit-observer registration as
  well as on exit events. This closes a registration race that could leave a
  command suspended forever with an unreaped child, even after its timeout.
- Preset normalization preserves optional launch-agent requirements, so the
  built-in GlobalProtect preset survives relaunch, migration, notification
  changes, and Shortcuts catalog lookup.
- Cancelled command submissions are removed from the queue, and cancellation
  reaches commands waiting for the process-operation gate without affecting
  other submissions.
- Keep Off detects a current-user PanGPS executable in the GlobalProtect bundle,
  even when no main app or helper runs. The card reports enforcement while that
  user agent remains; the protected root daemon is still left alone.
- Open rechecks running state after service work and requires fresh final
  evidence before reporting success, including when an initially running app
  exits during the operation.
- Search results below the unfiltered display limit retain keyboard selection
  across inventory refreshes while the process remains live.
- Overlapping Activity Monitor handoffs preserve the original table settings on
  the Accessibility worker queue. Stale restoration timers cannot undo a newer
  handoff, and shutdown restores changes from an in-flight attempt.

- Every shell command now stops burning a CPU core once its output ends. A pipe
  stays permanently readable after its writer closes, so the read sources kept
  firing at EOF and spun their I/O queue at 100% CPU until completion, starving
  the process-exit source that shares that queue. Each stream's source is now
  cancelled when it reaches EOF, `read` retries on `EINTR`, and an unrecoverable
  read error ends the stream instead of re-arming a source that can only fail
  again. Since `ps` and `nettop` run on every poll tick, this was continuous
  idle load.
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
- Every local tool now runs in the C locale (LC_ALL=C, LANG and LC_* removed),
  so a non-English locale can no longer make `ps` print decimals and start
  times the parser rejects; the parser also accepts a comma decimal.
- Command output is decoded lossily and an empty process inventory is treated
  as a read failure instead of an empty machine.
- Disk I/O is read from the kernel's per-process resource usage in bytes
  (shown in MB); the `ps inblock/oublock` columns print `-` on current macOS,
  so the Disk column was always empty and cost an extra `ps` per refresh.
- A process-list read cancelled by a poll restart is no longer recorded as the
  persistent "process list is stale" error.
- Refresh (in-app, URL, and Shortcuts) reports its own outcome instead of
  failing because of an older process-list error it did not touch.
- The process name is computed once per row and the sorted, filtered, and tree
  lists are memoized per inventory generation instead of being rebuilt on
  every view evaluation.
- A repeated pid in `ps` output fails the read instead of crashing or silently
  overwriting a row; the legacy six-token `ps` layout is no longer parsed, and
  a malformed row is dropped while the rest of the inventory is kept.
- The home-directory abbreviation in the command column applies only to the
  home directory itself or paths inside it.
- A slow inventory read that finishes late no longer overwrites a newer cached
  result, and failed reads are never cached.
- Process detail keeps internal runs of spaces in the command.
- A process selected through search that ranks below the display limit stays
  selected across polls and sort changes; the selection is reconciled against
  the full inventory and pruned only when a process exits or its pid is
  recycled.
- Typing a search, switching tree mode, or collapsing a node no longer
  deselects hidden rows; batch actions act on the full selection, which the
  confirmation lists.
- A global hotkey now requires Command or Control, and combinations macOS
  reserves (for example ⌘Q, ⌘Tab, ⌘Space) are refused with an explanation.
- Creating a quick auto-stop rule with a name that matches another process's
  rule is refused instead of silently overwriting that rule with a different
  executable path.
- The process list takes keyboard focus when a row is clicked, so arrow keys,
  Return, and Escape work without Full Keyboard Access.
- One Activity Monitor coordinator lives for the app's lifetime, its
  restoration runs on quit, and a field the user changed after the handoff is
  left alone.
- A search with no matches on a stale list shows the filter empty state with
  Clear Search & Filter, and a failed first load shows the error with Retry
  instead of "Idle Until Needed".
- The rule editor shows the store's validation error inside the sheet, and the
  rule editor and rename sheets close with Escape.
- Every watched preset row has a Delete button and context-menu item; deleting
  the built-in GlobalProtect preset is refused while Keep GlobalProtect Off is
  on, with the way out explained.
- Filtered tree ancestors expand once per filter change, so a node collapsed
  while searching stays collapsed, and disclosure state for exited processes
  is forgotten.
- Notification and rule-enable toggles carry accessibility labels.
- Settings sheets fit inside the Settings window.
- The memory highlight slider's grid includes its 1024 MB default.
- The process detail sheet ignores a read that finishes after the sheet moved
  to another process.
- The batch confirmation describes the captured targets, not live state.
- The inferred app path for "Watch This Process" uses the last path component
  ending in `.app`.
- Search text is persisted after a short pause in typing instead of on every
  keystroke, and any pending write is flushed on quit.
- Onboarding copy says to right-click a row, and onboarding is offered on the
  first interactive activation rather than only for an interactive launch.
- A cancellation that races a command's launch can no longer report
  "cancelled" while the child keeps running: the stop claims completion under
  the same lock the launch checks, and a command that had already exited
  reports its real exit instead of a cancellation.
- Local tools run under `zsh -f`, so a user's `.zshenv` cannot alias them,
  print into their output, or change their locale; children also start with
  default signal dispositions.
- A child terminated by a signal is reported as "terminated by SIGTERM" rather
  than "exited with status 15".
- Child exits are observed with a dispatch source and a non-blocking reap
  instead of one blocked worker thread per command.
- Activity Monitor Accessibility traversal runs off the main actor, resolves
  the PID column once, and reads only that cell per row, so an exact-PID
  handoff no longer freezes TaskScope's own window.
- Activity Monitor menu items are matched by title ("All Processes", "PID")
  and each change is confirmed by the menu's own checkmark before it is
  recorded for restoration; an unmatched menu leaves the table untouched.
- Notification requests are no-ops when TaskScope runs unbundled instead of
  crashing the process.
- Re-registering an unchanged hotkey is skipped; changing it unregisters the
  old combination first and restores it if the new one is refused.
- Turning Launch at Login off still attempts to unregister an "Unavailable"
  registration and shows the error if that fails.
- An interactive launch that is not active when the launch grace period ends
  stays a regular app and presents on the next activation instead of being
  demoted to an accessory with its windows hidden.
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
