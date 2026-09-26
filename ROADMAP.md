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

The GlobalProtect baseline now has a read-only self-check and an
[evidence matrix](GLOBALPROTECT_COMPATIBILITY.md). Its fixture tests and live
observation rows do not establish lifecycle or login/reboot compatibility.

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

## 1.1: Safer lifecycle configuration and support

### Versioned preset imports and dry run

Implemented baseline: exports carry schema version 1, legacy array imports
remain supported, archives are size-bounded, and a mandatory non-mutating
preview shows app/process/job fields, fixed daemon fields, duplicates, and
rejection reasons. Import performs no lifecycle action. Settings and the import
preview also provide a dry-run list of the later Open, Quit App, Quit Helpers,
Close All, launch-job, and protected-process behavior without performing it.

Remaining work:

- Add explicit migration functions when schema version 2 is designed.
- Extend fixtures with additional adversarial archives as new schema versions
  are introduced.

### Permission and installation health

Implemented: **Settings > Health** aggregates notification, Accessibility,
login-item, local signature/App Intents metadata, preset-path, and bundle-identity
checks. Denied, unavailable, stale, and unverified evidence remain distinct;
not-requested, off, and approval-required states are explicit. Results expire,
refresh after activation or configuration changes, and reject late collection
results. Recovery is limited to refresh and verified reversible navigation,
with targets rechecked on click. No automatic reset, re-sign, reinstall, login
registration, or lifecycle mutation is offered. Findings remain local and do
not expand the Support JSON export.

Focused tests exercise simulated permission revocation and app replacement,
unbundled execution, missing/malformed/optional paths, metadata limitations,
stale observations, cancellation, and failed/disappearing recovery destinations.
Signing integrity and metadata presence never claim actual Shortcuts readiness.

Remaining compatibility evidence: manually exercise permission revocation and
restoration, signed-app replacement, login/reboot, and Shortcuts discovery and
execution on the supported macOS/signing matrix. Record these independently of
the automated fixtures; do not infer a supported combination from a passing
local health check.

### Privacy-safe support diagnostics

Implemented lifecycle baseline: Settings > Support previews the complete JSON
before exact copy/save, with versions, permissions, anonymous selected-preset
identity, user launch-agent status, and the selected preset's recent redacted
failure summaries. The session history retains at most 20 failures, can be
cleared, and is never persisted or uploaded. Redaction/retention/export tests and
the exact field inventory in SUPPORT.md cover this boundary. Toolchain and
signature diagnostics remain outside this report to avoid private build and
organization identifiers.

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
