# TaskScope Roadmap

TaskScope currently provides source and local-development packaging. These
priorities describe remaining work, not promised release dates. Security,
data preservation, and accurate results take priority over new features.

## Distribution and compatibility

A public binary remains unready. Before offering one:

- Choose an owned bundle identifier and an explicit architecture policy.
- Test migration from development preferences, permissions, Shortcuts, and login
  identity, or document a deliberate break before installation.
- Complete hardened-runtime and entitlement review, Developer ID signing,
  notarization, stapling, Gatekeeper, checksums, and downloaded-copy QA.
- Verify install, upgrade, rollback, permissions, Shortcuts, URL refresh, login,
  and uninstall on a clean machine.
- Collect candidate-specific GlobalProtect lifecycle evidence required by the
  existing [release gate](RELEASE.md#globalprotect-compatibility-evidence-gate).

Until those checks pass, keep releases source-only and verify clean-clone build
instructions. Current arm64 observations do not establish Intel, universal, or
all macOS 14+ runtime compatibility. Build and manually test each claimed OS/CPU
combination separately.

GlobalProtect has a read-only self-check and [evidence matrix](GLOBALPROTECT_COMPATIBILITY.md).
Remaining coverage includes other layouts/versions, translated UI, Fast User
Switching and vendor UI routing, login/reboot persistence, management-policy
interference, and private-resource connectivity. Simulated tests and historical
observations cannot establish compatibility for a new build.

## Upgrades and recovery

Versioned preset archives, import review, lifecycle dry runs, bounded diagnostics,
Health checks, unknown-field preservation, and read-only recovery are implemented.
Remaining work includes:

- Design explicit preset-archive migrations when a new archive schema is introduced.
- Extend adversarial migration and recovery fixtures with each schema change.
- Verify preference preservation and permission continuity across real upgrades
  and signed-app replacement; document safe rollback paths without moving tags.
- Exercise live permission revocation/restoration, login/reboot, and Shortcuts
  discovery/execution across the claimed signing and macOS matrix.
- Keep support exports limited to previewable, redacted fields; evaluate any
  additional diagnostic data against privacy requirements before adding it.

If distribution later adds an updater, decide between manual downloads and a
signed update mechanism. Disclose any endpoint, transmitted data, cadence,
retention, failure behavior, and user control before shipping a network check.

## Accessibility and localization

- Move user-facing strings into localizable resources.
- Complete keyboard-only and VoiceOver checks for process review, confirmations,
  lifecycle reports, rules, Settings, and onboarding.
- Verify contrast, reduced motion, and larger text preserve status and action meaning.
- Review at least one localization or explicitly retain English-only support
  while using pseudo-localization to find layout defects.
- Validate destructive wording in every shipped language.

## Performance and maintenance

- Define measured budgets for idle CPU, memory, wakeups, refresh latency, and
  process-list interaction at representative inventory sizes.
- Record long-running menu-bar tests and confirm extended metrics stop when their
  final consumer exits.
- Test rapid refresh, rule changes, process exit, and view switching for bounded work.
- Revalidate permissions, Shortcuts, login, and managed lifecycle behavior on major
  macOS releases, and keep Swift/Xcode dependencies current.
- Follow the [security checklist](THREAT_MODEL.md#security-review-checklist) for
  trust-boundary changes and keep privacy, release, support, and uninstall docs
  synchronized with the implementation.

Cloud accounts, cross-device sync, remote process control, public preset catalogs,
and analytics are outside the current scope.
