# TaskScope Roadmap

This roadmap begins after the first source/development release. It is deliberately
bounded: future ideas are not release promises, and a milestone is complete only
when its acceptance criteria have evidence. Security, data-loss, and truthful
result-reporting regressions take priority over feature work.

## 1.0.x: Release operations and compatibility

### Production distribution decision

Decide whether TaskScope will remain source-distributed or ship a public binary.

Acceptance criteria for a public binary:

- an owned bundle identifier and explicit arm64-only or universal architecture
  policy are documented and verified from the artifact;
- existing development preferences and permissions are migrated and
  upgrade-tested, or the compatibility break is disclosed before installation;
- hardened runtime and entitlements are reviewed;
- the final artifact passes Developer ID signature, notarization, stapling,
  Gatekeeper, checksum, and clean-machine tests;
- installation, rollback, Shortcuts, URL refresh, login item, and uninstall are
  verified using the downloaded artifact;
- README, privacy, support, and release notes describe exactly that evidence.

Acceptance criteria for remaining source-only:

- no local staged bundle is attached or advertised as a production download;
- source prerequisites, architecture limitations, and signature behavior remain
  prominent;
- source archives and clean-clone instructions are verified on every release.

### Supported compatibility matrix

- Record automated builds and manual smoke results separately for the oldest and
  newest supported macOS.
- Exercise every supported CPU architecture on hardware or an appropriate VM.
- Label untested combinations as untested rather than supported by inference.
- Record tested GlobalProtect/macOS combinations separately from simulated
  lifecycle tests.
- Add a release checklist gate that prevents broader claims than the matrix.

### Update and rollback policy

- Decide manual downloads versus a signed updater.
- Prove an upgrade from 1.0 preserves every preference schema and permission
  identity intended to persist.
- Document and test rollback without moving tags or downgrading incompatible
  preferences.
- If a network update check is added, disclose its endpoint, data, cadence,
  retention, failure behavior, and user control before shipping.

### Hosted-runner continuity before 2026-11-02

The tracked `macos-14` GitHub-hosted runner is scheduled for retirement. Migrate
the compatibility job before 2026-11-02 rather than waiting for CI to fail.

- Track the migration in a repository issue with an owner and completion date.
- Select an available hosted image or a maintained self-hosted runner and record
  its macOS, Xcode, Swift, and CPU architecture.
- Preserve macOS 14 compatibility evidence through an appropriate machine/VM or
  explicitly narrow the claim; a newer runner compiling a macOS 14 deployment
  target is not runtime evidence.
- Prove the replacement workflow on a pull request before making its check
  required, then update branch rules without locking out maintenance.
- Remove the retired runner reference and archive the final successful old/new
  toolchain evidence.

## 1.1: Safer lifecycle configuration and support

### Versioned preset imports and dry run

- Add an explicit preset schema version with migration and round-trip fixtures.
- Show an import preview containing custom app path, process names, user
  launch-agent plist paths and labels, duplicates, and rejected fields. Display
  the immutable built-in GlobalProtect service fields separately as fixed.
- Guarantee import performs no lifecycle action.
- Add a dry-run report that lists every proposed local operation and the fixed
  built-in GlobalProtect privileged restoration, without signaling a process,
  launching an app, or requesting authorization.
- Test malformed, oversized, duplicate, legacy, and adversarial preset files.

### Permission and installation health

- Provide one diagnostics view for notification, Accessibility, login-item,
  signing/App Intents, preset path, and bundle identity status.
- Give every failed state a verified, reversible recovery action.
- Distinguish denied, unavailable, stale, and unverified results.
- Exercise recovery after permission revocation and app replacement.

### Privacy-safe support diagnostics

- Let the user preview every file and field before export.
- Exclude or redact commands, usernames, organization identifiers, preset
  paths, and managed-service data by default.
- Never upload diagnostics automatically.
- Add automated redaction tests and documented deletion steps.
- Keep enough version, toolchain, signature, permission, and failure-state data
  to diagnose packaging and lifecycle bugs without a full process list.

## 1.2: Accessibility, localization, and efficiency

### Accessibility and localization

- Move every user-facing string into a localizable resource.
- Complete keyboard-only and VoiceOver scripts for process review, destructive
  confirmation, watched lifecycle reports, rules, Settings, and onboarding.
- Verify increased contrast, reduced motion, and large text do not hide status
  or destructive-action meaning.
- Ship at least one reviewed localization or explicitly keep English-only while
  pseudo-localization catches layout defects.
- Validate destructive wording in every shipped localization.

### Performance and energy budgets

- Define budgets for idle CPU, resident memory, wakeups, refresh latency, and
  process-list interaction at representative inventory sizes.
- Run a long-lived menu-bar soak test and record the environment and results.
- Verify extended `nettop` collection stops when its final consumer exits.
- Test rapid refresh, rule evaluation, process exit, and view switching without
  unbounded work or retained history.
- Treat a budget regression as a release blocker unless a documented product
  decision changes the budget.

## Ongoing maintenance

- Re-run the security checklist in [THREAT_MODEL.md](THREAT_MODEL.md) for every
  trust-boundary change.
- Keep dependencies and Swift/Xcode compatibility current without broadening
  runtime claims automatically.
- Monitor bug and security reports without asking for private process data.
- Keep release, privacy, support, and uninstall instructions synchronized with
  actual artifacts.
- Revalidate Shortcuts, Accessibility, notifications, login items, and managed
  lifecycle behavior on major macOS releases.

Out of scope until the milestones above are complete: cloud accounts,
cross-device synchronization, remote process control, public preset catalogs,
and analytics-driven product behavior.
