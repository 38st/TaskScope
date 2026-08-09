# Changelog

All notable changes to TaskScope are documented in this file. The project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
