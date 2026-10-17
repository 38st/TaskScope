# Using TaskScope

## Process actions and observations

The process list supports search, CPU/memory/name/PID sorting, filters, and flat
or expandable tree views. When the display limit truncates results, **Showing
N of M** includes the total matching rows, including search results. Select All
selects displayed matching rows. Hidden selections remain selected until the
process exits or its identity changes; batch confirmation lists captured targets.
Click any tree row, including the selected row or a nested child, to return
keyboard focus for arrows, Return, and Escape.

Stop sends `SIGTERM`; explicit Force Stop sends `SIGKILL`. Normal process actions
never target TaskScope itself, launchd, the kernel task, or process groups.
Captured identities are revalidated immediately before signals. Missing PIDs,
changed identities, and unavailable verification produce different results.
A changed executable path is not proof that a still-running process exited.
A `<defunct>` row with no kernel executable path is treated as already exited
and is not signalled during manual, batch, or automatic stops; a missing path
alone does not establish exit. A stale single-stop target is replaced with the
verified inventory while preserving displayed Net/Disk readings.

Process start evidence uses UTC and names preserve UTF-8. Shared inventory cache
age and ordering use monotonic elapsed time, including sleep; wall-clock changes
cannot extend reuse, and negative ages expire the cache. Destructive checks use
uncached inventory. Open's main-process polling uses a monotonic deadline and an
attempt limit. Shell completion retries child reaping after early exit notifications
and stop requests, including command timeouts.

Commands cancelled while queued or waiting for admission are rejected. Once a
preset Stop acquires the process-operation gate, it completes even if its caller
cancels. Open remains cancellable; readiness waits stop polling and the result
acknowledges possible earlier app or service changes. Cancelled Open and commands
cancelled before execution are not retained as lifecycle failures.

The displayed-list update time changes when its backing inventory is replaced.
The stale watched-status banner tracks the last successful watched observation
separately and includes the date for observations before today. Explicit refresh
reports its own result even when joining a silent read. Presets remain visible
before the first watched observation and after read failures; Unknown and Stale
status and Retry distinguish missing evidence from a quiet app.

The All filter shows processes exposed by macOS. Watched main processes require
current-user ownership and an executable inside the preset's `Contents/MacOS`;
helpers require current-user ownership and an executable inside `Contents`.
Protected names remain classified across users for display. This display
classification does not authorize a signal or establish a launchd service identity.

Process details can copy a command or request exact selection in Activity Monitor.
The row's UTC start time and kernel executable path must match before opening,
on each selection retry, and after selection before success is reported. These
identity checks also support visible root-owned and other-user processes. If
Accessibility access is not granted, Activity Monitor can still open; this status
does not imply the user denied a request. Temporary search, scope, or PID-column
changes are restored after the handoff. Consecutive handoffs retain the original
state; fields subsequently changed by the user are left alone.

## Watched-app presets

Settings supports creation, editing, ordering, import, export, and a lifecycle
dry run. Exports use a versioned archive; legacy array imports remain accepted.
Import is size-bounded and previews configured fields and rejection reasons
without changing processes. A later user action can use those app paths, user
launch-agent labels/plist paths, and process names, so inspect untrusted imports.
Custom presets cannot configure privileged system daemons; the built-in
GlobalProtect privileged definition is immutable.

Helper/protected names and launch-agent labels/paths cannot contain commas.
Custom app paths use their on-disk spelling; main process names adopt the bundle
executable's spelling, and helper lists exclude the main process. Optional job
requirements survive normalization and saves.

**Watch This Process** and **Save Selection as Preset** validate every selected
process against the proposed main/helper name, owner, and executable-directory
boundaries before saving. Non-bundled tools receive no fabricated app path.
Extensions and XPC services can be helpers alongside their containing app's main
process, but are not accepted as that main process. TaskScope's own row disables
Watch This Process and Create Auto-Stop Rule.

Open and preset stop actions share lifecycle checks and per-job reporting. Quit
App, Quit Helpers, and Close verify final inventory against the definition
captured for the action even if the saved preset changes or is deleted. Preset
Quit, Close, and Keep Off give eligible processes up to three seconds to exit
before force stopping; confirmations disclose escalation. Partial reports do
not imply every target stopped or that no signal was sent.

For GlobalProtect's distinct full-stop and restoration behavior, read
[GlobalProtect](GLOBALPROTECT.md). Ordinary Quit App, Quit Helpers, and Shortcuts
Stop do not disconnect it and leave its VPN services alone.

## Runtime rules

Prompt, Auto Stop, and Log Only rules require current-user ownership and exclude
TaskScope itself and PIDs that cannot be signalled. Auto Stop requires a trusted
kernel executable path, checked again immediately before signaling. Symlinked
rule paths resolve to their targets. Legacy name-only Auto Stop rules load
disabled until reviewed.

The quick rule sheet shows the executable path or name-wide scope as you edit.
Supplying a path enables a disabled name-only Auto Stop rule, including migrated
legacy rules; the sheet and save message disclose this. Other disabled rules
remain disabled. A quick rule cannot silently overwrite another same-name rule.

Prompt alerts show a PID and are presented anew when the queued target changes.
An unanswered name-only prompt follows a still-matching process when its
executable moves within the same lifetime.
Dismissal survives rule toggles and executable moves for that process occurrence;
changing the rule action to Auto Stop or Log Only allows it to act again.
Rule edits revoke captured pre-signal authority without adding a failure event
for the cancelled automatic stop. Edits that keep Auto Stop enabled and matching
retain the occurrence's handled state and single-retry budget, including after
delivery. A retry waits at least one engine cadence
measured by a monotonic clock. Delivered requests remain in history even if
the rule is later edited, disabled, or deleted. An accepted request is shown as
Stop requested until exit is observed; a changed or unreadable executable path
alone cannot produce an Ended or Stopped event.

Log Only must reach durable event storage before the occurrence is treated as
handled. Event history retains at most 200 records. For mixed or unreadable
stored data and explicit-reset behavior, see [recovery](../SUPPORT.md#stored-data-is-unreadable).

## Saved selections

Saved entries use durable kernel executable-path matching and a recall preview.
Legacy entries can fall back to command/name matching and are identified in the
preview; path-backed entries never downgrade to that fallback. Saving refuses
entries without a kernel path. Multiple saved copies of one executable recall
running copies up to the saved count; extra copies require review.

## History, notifications, and hotkeys

CPU and RSS charts have Live, Paused, and Unavailable states and keep at most 60
samples in memory. Sampling pauses when no metrics view is visible. Changing
the interval schedules the next sample without an immediate sample burst.

Notifications require opt-in and system authorization. Editing a preset's
identity, app path, process-name assignments, or notification settings establishes
a new baseline instead of announcing false starts or stops.

The default shortcut is ⌃⌥⌘T. Supported saved shortcuts such as Command-Shift-T
are retained. Saved shortcuts rejected by current validation migrate to the
default, with a reason in **Settings > Hotkey** until dismissed or successfully
recorded. Shortcuts require Command or Control; unsupported keys and reserved
macOS shortcuts (including Lock Screen, Full Screen, Emoji & Symbols,
Spaces/Mission Control, and input sources) are refused. Recording errors remain
separate from actual registration/conflict status. See [hotkey recovery](../SUPPORT.md#stored-data-is-unreadable)
for unreadable preferences.

## Stored configuration

Retained rules, presets, selections, and events preserve unknown JSON fields
across saves. Rules with unknown fields are disabled and read-only because a
newer field may narrow their authority. Settings preserve newer values normalized
for display until that setting is changed. This preservation does not implement
newer behavior. Read [Privacy](../PRIVACY.md) before sharing exports or screenshots.
