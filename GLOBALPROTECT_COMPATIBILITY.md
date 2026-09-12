# GlobalProtect compatibility evidence

**GlobalProtect lifecycle compatibility unverified.** The self-check provides
read-only installation/state evidence for the fixed built-in preset. It does
not establish that Keep Off works across login/reboot or under any particular
management policy, or that Open restores a working VPN connection.

## Evidence collected

| Kind / date | macOS / architecture | GlobalProtect / TaskScope | Result | Limits |
| --- | --- | --- | --- | --- |
| Deterministic fixtures, 2026-09-12 | Host-independent data on macOS test runner | Simulated layouts and tool responses | Optional/missing agents, both disabled-output formats, unknown/error states, process ownership, protected PID validation, version handling, and redaction covered by `GlobalProtectCompatibilityTests` | No installed-product lifecycle actions |
| Live read-only observation, 2026-09-12 19:59 UTC | 26.6.2 (25G83), arm64 process | GlobalProtect 6.3.3-1121; TaskScope self-check working tree based on `059de91`, included in this change | [Redacted report](Evidence/GlobalProtect/2026-09-12-macos-26.6.2-gp-6.3.3-1121.txt): both user plists installed, disabled overrides, neither loaded; system plist installed, enabled override, not loaded; no matching processes observed | XCTest execution, no TaskScope app bundle version or Keep Off preference read; GlobalProtect build metadata unavailable; protected process not verified; no lifecycle or policy test |
| Managed lifecycle smoke | Untested | Untested | No result | Keep Off, TaskScope relaunch, login/reboot, Open/restoration and policy interference unverified |

The live report describes the Mac's existing state. The check did not create
that state and no repair was attempted. In particular, the absent protected
daemon is a coverage gap, not a successful protected-service validation. The
observation used Swift 6.3.3 and Xcode 26.6 (17F113). The test runner's own bundle
version is deliberately excluded from the TaskScope version fields.

Validation on the same macOS/toolchain, in an isolated checkout of this change:
12 focused fixture/UI checks passed; the live read-only probe passed separately.
The full suite passed 378 tests with zero failures and one opt-in live-test skip,
with coverage, warnings-as-errors, concurrency warnings, and actor race checks
enabled. The release build, packaging tests, shell syntax checks, and diff
whitespace checks also passed. These automated results do not replace the
untested lifecycle steps.

After integration with the support-diagnostics commit `1a37598`, the full strict
suite passed 391 tests with zero failures and the same one opt-in live-test skip.

macOS 14/15, other macOS releases, Intel, other GlobalProtect versions, and other
installed layouts remain untested for this feature. An arm64 process value
describes the running executable; it is not a hardware inventory or proof of
universal binary support.

## Repeatable read-only collection

1. Use the bundled app's **Compatibility Self-Check** on the GlobalProtect
   preset, or **Settings > Watched Apps > GlobalProtect**. Wait for the report.
2. Review all fields, including unknown states. Use **Refresh** after the state
   you intended to observe has settled; probes are not an atomic transaction.
3. Choose **Copy Summary** or **Export…** and retain the exact redacted text.
   Add the release/source revision and signing/install method separately.
4. Record the evidence kind as **live read-only observation**. Do not turn a
   snapshot into a pass/fail claim about actions that were never exercised.

The opt-in developer probe uses the same collector without reading app
preferences or performing lifecycle actions:

```bash
TASKSCOPE_LIVE_COMPATIBILITY=1 swift test \
  --filter GlobalProtectCompatibilityTests/testLiveReadOnlyEvidenceWhenExplicitlyRequested
```

Only the text between the report heading and its final manual-check reminder
is the redacted summary. The surrounding Swift build/test log can contain local
checkout paths; do not attach that raw log publicly. By default, the live test
is skipped so fixtures do not depend on any installed GlobalProtect version.

## Authorized lifecycle evidence

On a managed test machine approved for these operations, record a separate row
per macOS build, CPU architecture, GlobalProtect version/layout, and TaskScope
artifact/revision. Retain the baseline and each after-action self-check export.

| Step | Evidence to record |
| --- | --- |
| Baseline | Installed known agents, explicit overrides or plist defaults, loaded state, process counts, protected-service state |
| Enable Keep Off | Confirmation and actual lifecycle result; known user overrides disabled, user jobs unloaded, user-facing processes absent or failures explained |
| Relaunch TaskScope | Actual result and new report; distinguish preserved intent from observed launchd state |
| Log out/in or reboot | Which event occurred, user-agent/process state afterward, management software interference, and new report |
| Turn Keep Off off | Overrides enabled; no launch implied by this action; actual result and report |
| Choose Open | Actual user-agent restoration, app result, any administrator request/result for an absent protected daemon, and report |
| Protected service / VPN | Compare baseline and later system state; verify connectivity through the organization's supported method separately |

Record **pass**, **fail**, or **not tested** for each performed step, with the
observed result and redacted artifact references. Do not signal, restart, or
unload a protected daemon just to obtain evidence. System-state changes may be
caused by policy or other software; the self-check cannot attribute causation.

## Interpretation and privacy

- `pangpa` is the required known user agent; `pangps` is optional. Missing an
  optional plist alone is not an incompatibility. A loaded job or persistent
  override can survive removal of a plist, so all three states are independent.
- Explicit enabled/disabled overrides differ from **No override**. The latter
  defers to the installed plist's `Disabled` default. If the plist is missing,
  unreadable, or has a different label, that effective default is unverified.
- Failed, denied, timed-out, cancelled, or unrecognized reads are unknown, never
  evidence of absence. launchctl text is not a stable API; retain unknown
  results as gaps when macOS output changes.
- Current-user `PanGPS` is distinct from root `PanGPS`. Root ownership alone is
  insufficient to verify the protected system job: its PID and a kernel path
  within the known product directories must also match. This is an observation
  of identity/path, not signature validation or a service-health check.
- Only fixed public job labels, bounded version metadata, time, states, and
  process counts enter the report. Raw plist/launchd output, private process
  details, organization configuration, and network contents are not exported.
  Additional/relocated agents can be missed; the report is not a discovery of
  every vendor component installed on the Mac.

Review before sharing. Nothing uploads automatically. Remove exported files
and replace clipboard contents when finished. See [SUPPORT.md](SUPPORT.md) for
collection/recovery and [RELEASE.md](RELEASE.md) for the compatibility claim gate.
