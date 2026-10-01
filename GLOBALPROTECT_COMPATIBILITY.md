# GlobalProtect compatibility evidence

**GlobalProtect lifecycle compatibility unverified across login/reboot and
management policies.** An authorized live stop/restore cycle passed on the
specific Mac described below, including a subsequent Connected status. The
self-check alone provides read-only installation/state evidence and does not
establish lifecycle or VPN connectivity results.

The current Keep Off and in-app GlobalProtect Quit All implementation includes an explicitly authorized stop of
the fixed system VPN service. Earlier read-only evidence below predates this
behavior. Automated full-stop/restore fixtures do not establish live VPN,
login/reboot, or managed-policy compatibility. See the separate
[September 28 live test](Evidence/GlobalProtect/2026-09-28-live-stop-restore.md)
for the exercised behavior, exact binaries, and limitations.

The later [passwordless restoration test](Evidence/GlobalProtect/2026-09-28-passwordless.md)
verifies Open and Keep Off without repeated administrator prompts on that
session-agent installation. The separate system daemon remains disabled;
Open no longer re-enables a service that the session restoration path does not
use. System-only layouts retain the administrator path.

Quit All now uses the full Keep Off path. Normal full stops press the vendor's
Disconnect control through Accessibility and require a stable idle
state before changing launch jobs: Not Connected, or Error accompanied by
Connection Failed, an enabled Connect control, and no Disconnect control in
the same vendor window. The UI adapter currently recognizes the
English status/control labels; unsupported layouts or states fail without
stopping services. URL Close and Shortcuts Stop retain their existing scope.
After a failed attempt, **Stop Services Anyway…** offers a separately confirmed
exception that skips the idle-state prerequisite, discloses stale-DNS risk, and
uses the same fixed service controls. The [October 1 recovery check](Evidence/GlobalProtect/2026-10-01-disconnect-recovery.md)
verifies failure/result visibility, cancellation, and the confirmed recovery
with an unresponsive vendor UI on this Mac.
The [automatic Quit All test](Evidence/GlobalProtect/2026-09-28-quit-all.md)
records two connected-to-off cycles with public HTTPS working afterward and
the final installed build's unchanged menu-bar frame.

The [restore regression follow-up](Evidence/GlobalProtect/2026-09-29-restore.md)
records the enabled-but-unloaded service failure and duplicate UI, the fix that
makes toggle-off perform a complete restoration, final live checks, and the
remaining limits of the orphan-recovery validation.

The [menu-bar Quit All follow-up](Evidence/GlobalProtect/2026-09-29-menu-quit-all.md)
covers persistent progress/results and full shutdown from the vendor's failed
connection view. It does not establish that an unreachable VPN portal can connect.

On the tested 6.3.3-1121 layout, the GUI-session `pangps` job runs a setuid
PanGPS process as root. A root process therefore does not by itself establish
that `pangpsd` is running. When the session agent is installed, Open restores
that service and verifies its launchd PID and executable; only layouts without
it require the separate system daemon. The vendor also documents a related
[daemon-to-session-agent startup failure](https://docs.paloaltonetworks.com/globalprotect/release-notes/6-3/globalprotect-addressed-issues/globalprotect-6-3-3-h9-windows-and-macos-addressed-issues)
when pre-logon is disabled. This reference does not establish that every vendor
build shares the same bug or behavior.

## Evidence collected

| Kind / date | macOS / architecture | GlobalProtect / TaskScope | Result | Limits |
| --- | --- | --- | --- | --- |
| Deterministic fixtures, 2026-09-12 | Host-independent data on macOS test runner | Simulated layouts and tool responses | Optional/missing agents, both disabled-output formats, unknown/error states, process ownership, protected PID validation, version handling, and redaction covered by `GlobalProtectCompatibilityTests` | No installed-product lifecycle actions |
| Live read-only observation, 2026-09-12 19:59 UTC | 26.6.2 (25G83), arm64 process | GlobalProtect 6.3.3-1121; TaskScope self-check working tree based on `059de91`, included in this change | [Redacted report](Evidence/GlobalProtect/2026-09-12-macos-26.6.2-gp-6.3.3-1121.txt): both user plists installed, disabled overrides, neither loaded; system plist installed, enabled override, not loaded; no matching processes observed | XCTest execution, no TaskScope app bundle version or Keep Off preference read; GlobalProtect build metadata unavailable; protected process not verified; no lifecycle or policy test |
| Authorized live lifecycle, 2026-09-28 | 26.6.2 (25G83), arm64 | GlobalProtect 6.3.3-1121; TaskScope 1.0.0 (3), local development build | [Redacted stop/restore record](Evidence/GlobalProtect/2026-09-28-live-stop-restore.md): fixed user and system jobs disabled/unloaded; Open re-enabled them and restored the session service and UI; VPN reported Connected | Initial reconnect required retry. Stale VPN DNS remained after some stops, even following Disconnect; Open recovered DNS and a subsequent idle stop preserved it. Login/reboot, private-resource reachability, and management-policy interference not tested |
| Passwordless session lifecycle, 2026-09-28 | 26.6.2 (25G83), arm64 | GlobalProtect 6.3.3-1121; TaskScope source `3c8d401` | [Follow-up record](Evidence/GlobalProtect/2026-09-28-passwordless.md): Open restored the session service with the system job still disabled; VPN reached Connected; Keep Off stopped all processes; no administrator window during these actions; public HTTPS worked afterward | Initial system-disable approval was required. Other layouts, pre-login, logout/reboot, policy changes, and private-resource connectivity remain untested; earlier DNS limitation is not fixed |
| Automatic Quit All, 2026-09-28 | 26.6.2 (25G83), arm64 | GlobalProtect 6.3.3-1121; TaskScope 1.0.0 (3), final executable `0742281e…` | [Live record](Evidence/GlobalProtect/2026-09-28-quit-all.md): TaskScope pressed Disconnect, verified Not Connected, disabled/unloaded all known jobs and stopped all processes; public HTTPS worked; final menu-bar frame unchanged | One-time Accessibility authorization required. English UI exercised; other layouts, policies, login/reboot, and private-resource connectivity untested |
| Restore regression, 2026-09-29 UTC | 26.6.2 (25G83), arm64 | GlobalProtect 6.3.3-1121; TaskScope executable `35383249…` | [Follow-up](Evidence/GlobalProtect/2026-09-29-restore.md): toggle-off restored service and one UI; healthy Open preserved PIDs and connection; final state Connected with public HTTPS working | Orphan recovery and direct-UI duplicate prevention unit-tested; exact orphan setup on final binary aborted because clean disconnect was not confirmed. Other layouts, policy, login/reboot and private resources untested |
| Menu-bar Quit All, 2026-09-29 UTC | 26.6.2 (25G83), arm64 | GlobalProtect 6.3.3-1121; TaskScope executable `81e7ae1f…` | [Follow-up](Evidence/GlobalProtect/2026-09-29-menu-quit-all.md): two final menu-bar full stops from Connection Failed; visible progress and one result sheet; zero vendor processes; Open restored one UI and service; public HTTPS 200 | Portal connection attempts reported unreachable/unresponsive, so no new connected-to-off cycle; translated UI, other layouts, policy and reboot untested |

The September 12 live report describes the Mac's existing state. The check did not create
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
| Enable Keep Off | Confirmation and actual lifecycle result; known user and system overrides disabled, all known jobs unloaded, user-facing and system processes absent or failures explained |
| Relaunch TaskScope | Actual result and new report; distinguish preserved intent from observed launchd state |
| Log out/in or reboot | Which event occurred, user-agent/process state afterward, management software interference, and new report |
| Turn Keep Off off | Full Open restoration: required overrides cleared, VPN service and one UI running; unused system daemon stays disabled on session-agent installations |
| Choose Open | Actual user-agent restoration, app result, any administrator request/result for an absent protected daemon, and report |
| Protected service / VPN | Compare baseline and later system state; verify connectivity through the organization's supported method separately |

Record **pass**, **fail**, or **not tested** for each performed step, with the
observed result and redacted artifact references. Only the explicitly approved Keep Off or GlobalProtect Quit All action may unload the fixed system
daemon. Record its absence after stopping and verified identity after Open;
never directly signal it or restart a loaded daemon just to obtain evidence. System-state changes may be
caused by policy or other software; the self-check cannot attribute causation.

## Machine-checkable release evidence

`script/release.sh --preflight` and `--release` require authorized lifecycle
evidence before checking signing credentials or building a public binary.
**The existing fixtures and live read-only report do not satisfy this gate.**
There is currently no qualifying lifecycle manifest, so public-binary preflight
fails. Source/development packaging remains available and must retain the
**GlobalProtect lifecycle compatibility unverified** notice.

For a candidate with `VERSION=V` and `BUILD_NUMBER=B`, retain one plain UTF-8
`*.evidence` file per claimed macOS build / architecture / GlobalProtect version
and agent layout under `Evidence/GlobalProtect/lifecycle/V-B/`. All manifests
in that directory must pass; at least one is required. These files define the
tested combinations, not a claim for other macOS releases or product versions.
Use a separate manifest for each persistence event if claiming both logout/login
and reboot coverage.

Each record is a literal `key=value` line. Values are case-sensitive, nonempty,
and contain no whitespace. Blank lines and lines beginning with `#` are allowed.
Duplicate or unknown keys, malformed lines, missing fields, and unsupported
schema versions fail. These are data files; they are never sourced as shell
code. There is no environment override or skip switch for this gate.

| Required field | Accepted value / meaning |
| --- | --- |
| `schema_version` | Exactly `1` |
| `evidence_kind` | Exactly `authorized-lifecycle`; this attests that the managed test machine was approved for these operations |
| `test_date` | Test date in `YYYY-MM-DD` syntax |
| `taskscope_version`, `taskscope_build` | Exact candidate `VERSION` and `BUILD_NUMBER` |
| `source_revision` | Full 40-character lowercase Git commit SHA, present locally and an ancestor of `HEAD` (or `HEAD` itself) |
| `bundle_id` | Exact `TASKSCOPE_BUNDLE_ID` supplied to the release script |
| `signing_kind` | `ad-hoc`, `apple-development`, or `developer-id`, as observed on the tested bundle |
| `install_method` | `staged-bundle`, `local-install`, or `downloaded-archive` |
| `macos_version`, `macos_build` | Numeric version such as `26.6.2`, and Apple build identifier such as `25G83` |
| `architecture` | Exactly `arm64`, matching the current release policy |
| `globalprotect_version` | Two to four numeric version components, optionally followed by a numeric hyphen suffix, e.g. `6.3.3-1121`; retain the suffix when present |
| `agent_layout` | `pangpa-only` or `pangpa-and-pangps`, from installed known agents |
| `persistence_event` | `logout-login` or `reboot`, whichever was actually performed |
| `coverage_gaps` | Exactly `none`; unknown probes, unexpected labels, unverified protected service, policy interference, or skipped checks prevent a pass |
| `manual_results` | Path to the redacted manual observations described below |
| `result_<step>` | Exactly `pass` for **each** of the nine steps below; `fail`, `not-tested`, `unknown`, and every other value block release |
| `report_<step>` | A distinct retained self-check export path for **each** of the first six steps below |

The nine exact step names are `baseline`, `keep_off`, `relaunch`, `persistence`,
`keep_off_disabled`, `open`, `protected_service`, `vpn`, and `managed_policy`.
The first six correspond to baseline and the five after-action exports in the
authorized lifecycle procedure. `keep_off_disabled` means turning Keep Off off
without implying an app launch. `protected_service` records the baseline/later
comparison and verified identity; `vpn` records restoration checked through the
organization's supported method; `managed_policy` records whether management
interfered throughout the sequence. Absence is required after Keep Off; a verified running service in the
installed launchd domain is required at baseline and after Open.

All referenced paths are repository-relative and must stay inside the same
`Evidence/GlobalProtect/lifecycle/V-B/` directory. Paths may contain only ASCII
letters, digits, `.`, `_`, `-`, and `/`, starting with a letter or digit; absolute
paths, `.`/`..` path components, doubled slashes, and symlinks (including parent
directories) are rejected. Every manifest and referenced artifact must be a
readable, nonempty regular file tracked by Git. Review/redact and `git add` new
evidence before preflight; the full release additionally requires a clean
worktree. Keep exports unchanged after redaction review and record observed
outcomes, signing/install details, administrator requests/results, and all nine
manual checks in `manual_results`. Do not retain raw tool logs or private VPN
configuration.

The candidate's tracked content must match `source_revision`, including staged
and unstaged changes, except for `Evidence/GlobalProtect/`,
`GLOBALPROTECT_COMPATIBILITY.md`, `RELEASE.md`, and `CHANGELOG.md`. This allows
evidence and its documentation to be committed after testing without a circular
commit SHA. Any other content change requires a new tested revision. Preflight
does not replace the full release's clean-worktree check.

This deliberately incomplete template illustrates all required fields for the
current candidate. Replace the placeholders and every `not-tested` only after
collecting the corresponding evidence; copying it unchanged must fail:

```text
schema_version=1
evidence_kind=authorized-lifecycle
test_date=YYYY-MM-DD
taskscope_version=1.0.0
taskscope_build=3
source_revision=FULL_TESTED_COMMIT_SHA
bundle_id=YOUR_PRODUCTION_BUNDLE_ID
signing_kind=OBSERVED_SIGNING_KIND
install_method=OBSERVED_INSTALL_METHOD
macos_version=TESTED_MACOS_VERSION
macos_build=TESTED_MACOS_BUILD
architecture=arm64
globalprotect_version=TESTED_GLOBALPROTECT_VERSION
agent_layout=OBSERVED_AGENT_LAYOUT
persistence_event=PERFORMED_EVENT
coverage_gaps=not-tested
manual_results=Evidence/GlobalProtect/lifecycle/1.0.0-3/environment/manual.md
result_baseline=not-tested
result_keep_off=not-tested
result_relaunch=not-tested
result_persistence=not-tested
result_keep_off_disabled=not-tested
result_open=not-tested
result_protected_service=not-tested
result_vpn=not-tested
result_managed_policy=not-tested
report_baseline=Evidence/GlobalProtect/lifecycle/1.0.0-3/environment/baseline.txt
report_keep_off=Evidence/GlobalProtect/lifecycle/1.0.0-3/environment/keep-off.txt
report_relaunch=Evidence/GlobalProtect/lifecycle/1.0.0-3/environment/relaunch.txt
report_persistence=Evidence/GlobalProtect/lifecycle/1.0.0-3/environment/persistence.txt
report_keep_off_disabled=Evidence/GlobalProtect/lifecycle/1.0.0-3/environment/keep-off-disabled.txt
report_open=Evidence/GlobalProtect/lifecycle/1.0.0-3/environment/open.txt
```

Place the manifest itself directly in `1.0.0-3/`, for example
`environment.evidence`; referenced artifacts may use subdirectories. Update the
human evidence matrix and release notes to match the actual tested combinations.
The gate validates the manifest, source binding, and presence of retained files.
It does **not** interpret export contents, authenticate manual attestations,
exercise lifecycle actions, or certify VPN health. Reviewers must compare each
export and manual observation with the recorded results. A passing manifest for
an ad-hoc test bundle does not establish Developer ID or downloaded-binary QA.

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
