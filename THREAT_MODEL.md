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
- never signal TaskScope itself;
- require a separate, explicit Force Stop confirmation for `SIGKILL`;
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

- reach this path only through an explicit user-approved lifecycle action;
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

### URL, Shortcut, and login automation

Any local app, webpage handler, or document can attempt to open a custom URL.
Shortcuts, in contrast, are actions explicitly configured and invoked by the
user under macOS App Intents controls.

Required invariants:

- accept only `taskscope://refresh` through the custom URL scheme;
- reject URL requests to open/stop presets or quit TaskScope;
- queue a cold-launch refresh without activating unnecessary UI;
- route user-configured Shortcut actions through the same identity validation
  and truthful result reporting as the app;
- do not treat local/development signing as proof of production artifact
  identity;
- make Launch at Login optional and recover visibly from macOS approval states.

### Preferences, exports, and recovery

Standard preferences store settings, preset/rule data, saved process matching
fields, event history, and corruption backups. They are local but not encrypted
or protected from the current user.

Required invariants:

- decode versioned data defensively;
- preserve the first unreadable payload instead of overwriting it with defaults;
- block persistence that would silently destroy unreadable primary data;
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
