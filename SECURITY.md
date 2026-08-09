# Security Policy

## Supported versions

| Version | Security support |
| --- | --- |
| `main` | Active development; not a stable release |
| Latest published release | Supported |
| Older releases | Upgrade before requesting a security fix |

Before the first GitHub release is published, only `main` exists. A changelog
entry or local app bundle is not a published release.

## Reporting a vulnerability

Do not open a public issue, discussion, or pull request for a suspected
vulnerability. Do not include exploit details or private process and
organization data in a public channel.

If the repository's GitHub Security tab displays **Report a vulnerability**, use
that form for a private report. Include the affected version/build, macOS
version and architecture, impact, and minimal reproduction steps. Remove
usernames, organization details, process command lines, preset paths, and other
machine-specific data unless essential.

Private vulnerability reporting is not currently assumed to be enabled. If the
button is absent, no alternative confidential contact has yet been published.
Retain the report privately rather than posting it publicly. Repository
maintainers must enable and verify a confidential channel before inviting
public security reports; this policy must then be updated with that channel.

No response-time promise is made until a working private channel and its
maintainer coverage have been verified. Confirmed reports should remain private
until a fix and coordinated disclosure plan are ready.

## Security-sensitive behavior

TaskScope can inspect visible local processes and can signal a selected target
only where macOS permits the current user to do so. A user can also choose a
Force Stop action that sends `SIGKILL`, subject to the same macOS permission
boundary. TaskScope can request administrator approval only to restore the fixed
system launch daemon in the immutable built-in GlobalProtect definition. Custom
presets cannot configure privileged daemon jobs, and TaskScope does not bypass
macOS authorization.

Imported watched-app presets are untrusted configuration. Importing a preset
must not execute it, but a later user-approved lifecycle action can use its app
path, user launch-agent plist path and label, and process names. Review every
field before acting. Imports cannot create or modify privileged system-daemon
behavior.

The custom URL scheme accepts refresh only. Destructive preset actions and app
quit are intentionally excluded because another local app or browser can open a
custom URL. The complete security model and residual risks are documented in
[THREAT_MODEL.md](THREAT_MODEL.md).
