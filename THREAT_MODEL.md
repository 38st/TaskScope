# TaskScope Threat Model

This document describes TaskScope's security boundaries and the invariants that
must remain true as the app evolves. It is a design and review aid, not a claim
that a particular artifact is signed, notarized, sandboxed, or vulnerability
free. Update it whenever process actions, lifecycle jobs, automation,
persistence, permissions, or distribution change.

## Scope

In scope:

- local process discovery, display, selection, and signaling;
- auto-stop rules and saved selections;
- watched-app presets, imports, and lifecycle actions;
- custom user launch-agent jobs and the immutable built-in GlobalProtect
  system-daemon restoration path;
- custom URLs, App Intents/Shortcuts, login items, and notifications;
- preferences, corruption backups, local logs, and preset exports;
- bundle identity, local packaging, signing, installation, and upgrades.

The security of macOS, Xcode, SwiftPM, Apple signing/notarization services,
GlobalProtect, and other managed applications is outside TaskScope's direct
control. TaskScope must nevertheless fail safely when those dependencies are
missing, denied, or return unexpected data.

## Assets and security goals

TaskScope should protect:

- **Process integrity:** signal only the process identity the user reviewed or a
  rule captured, never a recycled PID or a different queued target.
- **System availability:** make destructive actions explicit, keep protected
  processes out of ordinary stop paths, and never target TaskScope itself.
- **Privilege boundaries:** request administrator approval only for visible
  restoration of the fixed daemon in the immutable built-in GlobalProtect
  definition; never let a custom preset add privileged behavior, retain
  credentials, or bypass authorization.
- **Configuration integrity:** validate imported and persisted lifecycle fields,
  preserve unreadable data, and avoid reporting unsaved mutations as durable.
- **Local privacy:** do not transmit process or organization data, and minimize
  its appearance in exports, notifications, and logs.
- **Release integrity:** never represent an ad-hoc or development-signed bundle
  as Developer ID-signed, notarized, universal, or broadly runtime-tested.

## Actors and assumptions

- The interactive macOS user is trusted to approve a clearly described process
  or lifecycle action.
- A preset file, custom URL, process name, process output, local preference, and
  other same-user application are untrusted inputs.
- A same-user local adversary may open a custom URL, alter an exported preset,
  race process exit/PID reuse, or edit preferences. TaskScope should prevent
  those inputs from silently becoming a different destructive action.
- A system administrator controls authorization policy, protected services,
  managed application versions, and writable install locations.
- Malware already running with the user's or administrator's authority is not
  fully contained by this utility; macOS authorization remains the final
  boundary for privileged operations.

## Trust boundaries and required invariants

### Process inventory to signal delivery

TaskScope reads process data through local macOS tools. PIDs are reusable and a
displayed row can become stale at any suspension point.

Required invariants:

- operate only on visible processes and signal only where macOS permits;
- capture a process identity, including start evidence and the kernel-resolved
  executable path when available, before confirmation;
- re-read and compare identity immediately before sending a signal;
- distinguish “not present,” “identity changed,” and “could not verify”;
- never turn an unreadable inventory into a success or stale-target claim;
- never signal TaskScope itself, launchd (pid 1), the kernel task, or a process
  group; the parser drops such rows and every signal path refuses them;
- treat a protected process name as the protected system daemon only when the
  process runs as root, so a same-named per-user instance is never mistaken
  for it;
- require a separate, explicit Force Stop confirmation for `SIGKILL`; preset
  Quit, Close, and Keep Off escalate to `SIGKILL` only after a disclosed
  graceful window (3 seconds) with the identity still present;
- require an executable directory for every scoped termination; there is no
  name-only termination entry point;
- bind queued prompts and batch reports to immutable captured targets.
- require enabled automatic-stop authority to include a trusted executable path
  and match that path again in the final inventory immediately before signal.
- never downgrade a path-backed saved selection to legacy command/name matching.

### Watched presets and imported configuration

A custom preset contains an app path, process names, and optional user
launch-agent labels and plist paths. These values can name real local resources
even though the format does not contain a general-purpose shell command. The
immutable built-in GlobalProtect definition additionally contains fixed
protected-process and system-daemon fields; a custom preset cannot add or alter
them.

Required invariants:

- importing parses and validates data but performs no lifecycle action;
- bound imported file size, recognize an explicit archive schema version, and
  show every lifecycle field plus rejection reason before import is committed;
- require absolute `.app` and `.plist` paths and valid non-empty labels/names;
- reject duplicate identities, invalid mappings, and any privileged daemon
  fields on a noncanonical preset;
- require the built-in GlobalProtect identity and all of its privileged fields
  to match the fixed canonical definition exactly;
- present custom configured fields for review before destructive use;
- construct fixed tool invocations without evaluating a preset value as shell
  source;
- treat the built-in GlobalProtect preset as version-specific configuration,
  not authority to alter arbitrary protected processes;
- keep protected process names out of the normal killable-name set.

Keep Off polling also recognizes the optional per-user PanGPS executable when
the preset has the fixed supported GlobalProtect identity, the kernel executable
path is inside that bundle, and the non-root UID matches the current user.
A bare name, unknown UID, another user's process, or the root daemon cannot
trigger this additional enforcement path. Enforcement still disables/unloads
only the fixed user launch-agent labels; it never signals PanGPS directly.

Residual risk: a syntactically valid custom preset can intentionally point at
the wrong local app or user launch agent. The mandatory import preview exposes
those fields but cannot decide whether the user intended them, so users must
still trust and inspect the source. This risk cannot create a custom privileged
system-daemon operation.

### Privileged daemon restoration

TaskScope may request macOS administrator authorization only to bootstrap the
fixed system launch daemon in the immutable built-in GlobalProtect definition.
Custom presets cannot configure this path. The approval dialog is a high-risk
boundary.

Required invariants:

- reach this path only through an explicit user-approved lifecycle action, and
  only when launchd reports the daemon as not loaded; a loaded daemon is
  waited on, never restarted (`kickstart -k` is never issued for it);
- show that the built-in GlobalProtect restoration operation needs approval;
- verify the complete built-in identity and its fixed plist path and job fields
  before requesting approval;
- escape data as arguments and preserve intended script structure;
- never store a password or claim that authorization succeeded without checking
  the command and postcondition;
- report partial job failures individually;
- never remove, rename, or rewrite the configured plist as recovery behavior.

Residual risk: administrator authorization grants the fixed restoration command
elevated effect. Managed security software can reject or undo the operation;
TaskScope must direct users to their organization rather than escalating around
management controls.

### Persistent GlobalProtect user-agent suppression

The built-in preset can persistently disable and unload the known GlobalProtect
jobs in the current user's launchd domain. This is intentionally stronger than
an ordinary process stop and can prevent a required VPN UI or per-user service
from running.

Required invariants:

- require visible in-app confirmation before first enabling Keep Off;
- restrict the UI and persisted preference to the immutable built-in identity;
- operate only on the fixed per-user `pangpa` and optional `pangps` labels;
- never disable, unload, or signal a protected system launch daemon;
- re-enable user agents only through an explicit Open or toggle-off action;
- clear the persistent disable before bootstrap (launchd refuses to bootstrap a
  disabled job) and report each job result;
- re-check the persisted intent inside the operation gate before background
  enforcement acts, so enforcement queued behind an Open cannot undo it;
- preserve startup enforcement across app relaunch and login without exposing a
  destructive URL route.

Residual risk: endpoint-management software can restore the jobs, and product
versions can move `PanGPS` between user and system launchd domains. TaskScope
handles the known user-agent variants but does not override system policy.

### URL, Shortcut, and login automation

Any local app, webpage handler, or document can attempt to open a custom URL.
Shortcuts, in contrast, are actions explicitly configured and invoked by the
user under macOS App Intents controls.

Required invariants:

- accept only `taskscope://refresh` through the custom URL scheme;
- reject URL requests to open/stop presets or quit TaskScope;
- queue a cold-launch refresh without activating unnecessary UI;
- discard cancelled queued commands before dispatch and carry cancellation into
  a command waiting for the process-operation gate; cancelling one submission
  must not cancel its neighbors or imply that completed mutations were undone;
- route user-configured Shortcut actions through the same identity validation
  and truthful result reporting as the app; a Shortcuts stop runs without the
  in-app confirmation dialog, so configuring the shortcut is the confirmation;
- do not treat local/development signing as proof of production artifact
  identity;
- make Launch at Login optional and recover visibly from macOS approval states.

### Preferences, exports, and recovery

Settings > Health has a separate read-only probe surface with no lifecycle,
permission-request, registration, or preference writer. It checks local signing
integrity with network access disabled, bounded regular-file metadata, and
running/on-disk identity without reporting signature integrity as notarization,
distribution trust, or Shortcuts execution. Unknown access remains unverified;
inaccessible files do not become missing files. Optional paths and corrupt-store
fallbacks retain their distinct meaning. Expired observations and canceled
collections cannot authorize recovery. Recovery only navigates to verified local
destinations, rechecks the target on click, and never silently resets TCC,
registers login items, reinstalls/re-signs an app, or executes a Shortcut.
Findings stay in memory and do not extend the support export schema.

Support diagnostics are a separate export boundary from preset backups. The
report model accepts fixed status/action/reason categories, booleans, counts,
timestamps, and strictly numeric version metadata. It never serializes raw
presets, command results, inventory, logs, or error strings. Custom preset UUIDs
are used only for in-memory filtering and replaced with a report-local reference;
only a verified built-in identity receives the fixed GlobalProtect kind.
Lifecycle failure retention is bounded to 20 session entries and raw job data is
reduced to counts at capture. Collection performs read-only permission/file/job
checks without administrator prompts or lifecycle mutation. The entire JSON is
previewed before explicit copy/save, using the same immutable byte buffer.
Tests exercise adversarial names, commands, paths, errors, metadata, identity
spoofing, retention, and equality of preview/file contents. This does not redact
ordinary lifecycle sheets, preset exports, picker screenshots, or local logs.

Standard preferences store settings, preset/rule data, saved process matching
fields, event history, and corruption backups. They are local but not encrypted
or protected from the current user.

Required invariants:

- decode versioned data defensively;
- preserve the first unreadable payload instead of overwriting it with defaults;
- block persistence that would silently destroy unreadable primary data;
- preserve optional launch-job requirements through normalization and migration
  so valid built-in presets round-trip without entering corruption recovery;
- require an explicit destructive reset to resume writes;
- never export a fallback empty collection as if it were a valid backup;
- keep auto-stop history bounded and live chart samples in memory;
- document that changing the bundle identifier changes the preference domain
  and requires a tested migration or an explicit data-loss warning.

### Logs, notifications, and reports

Process and preset names can identify a person, organization, or sensitive
application even when they never leave the Mac.

Required invariants:

- no analytics or automatic diagnostic upload;
- do not log full process command lines or imported lifecycle payloads;
- use private log interpolation unless a field is demonstrably nonsensitive;
- notify only after opt-in and avoid false transitions during reconfiguration;
- tell users to sanitize screenshots, logs, exports, and bug reports.

### Build and distribution

The local build/install scripts create a same-machine bundle using an Apple
Development identity when available or ad-hoc signing otherwise. They build the
current architecture and do not notarize. The separate credential-gated release
pipeline can produce a Developer ID-signed, hardened, arm64, notarized artifact,
but only when its real Apple credentials and automated checks succeed.

Required invariants:

- keep bundle identifier, version, build, architecture, and signature claims
  consistent with the artifact;
- verify the bundle after copying and after installation;
- replace an installed bundle transactionally and restore it on failure;
- do not publish a local staged app as a production binary;
- require Developer ID signing, hardened runtime review, notarization, stapling,
  checksums, and clean-machine verification before claiming a public binary;
- treat a production bundle-ID change as a data/permission migration event.

## Abuse cases and expected response

| Abuse case | Expected response |
| --- | --- |
| Browser opens `taskscope://stop/...` | Reject without a process action. |
| PID exits and is reused after confirmation | Identity revalidation prevents the signal and reports the changed target. |
| Process changes executable after confirmation | Executable-path identity revalidation prevents the signal. |
| Process inventory fails | Report verification failure; do not claim stopped or stale. |
| Imported custom preset contains a relative plist path or any system-daemon job | Reject that preset without executing it. |
| Valid-looking custom preset points at an unintended user launch agent | Show the field and later-operation summary before import; require the user to reject an unintended path. |
| Preferences contain malformed JSON | Preserve backup, enter read-only recovery state, require explicit reset. |
| Privileged bootstrap fails or is denied | Report failure and leave the managed files intact. |
| Ad-hoc bundle is presented as a production binary | Release gate rejects the claim and artifact. |

## Security review checklist

For every release and trust-boundary change:

1. Add a regression test that fails before the security fix.
2. Run the complete gate in [RELEASE.md](RELEASE.md).
3. Exercise signals only against disposable controlled processes.
4. Test missing, malformed, denied, partial-failure, cancellation, and PID-reuse
   paths.
5. Inspect imported-data handling and every shell/AppleScript argument boundary.
6. Review logs, notifications, exports, and public error text for private data.
7. Verify actual artifact architecture and signing/notarization state.
8. Update this document, [PRIVACY.md](PRIVACY.md), and the changelog.

Vulnerabilities should be reported according to [SECURITY.md](SECURITY.md).
