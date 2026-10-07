# Release and Rollback Guide

This is the maintainer runbook for producing an honest TaskScope release. A
release is complete only when its tag, notes, artifacts, and documented claims
match independently verified evidence. A changelog entry, local install, or
staged app is not itself a published release.

## Current 1.0.0 scope

- Version: `1.0.0`
- Build: `3` (the 1.0.0 tag carries build `2`; `script/release.sh` refuses a
  build number that is not greater than every `v*` tag's)
- Deployment target: macOS 14
- Verified packaging architecture: arm64 only
- Distribution: GitHub source release and local-development packaging
- Local bundle identifier: `com.local.TaskScope`
- Possible local signatures: Apple Development or ad-hoc
- Not provided or claimed: production bundle identity, universal/Intel binary,
  Developer ID signature, hardened-runtime review, notarization, stapling, or a
  public downloadable app bundle

Do not attach `dist/build.noindex/TaskScope.app` or an archive of it to the GitHub 1.0.0
source release as a production binary. GitHub's generated source archives are
the only release artifacts within this scope unless the credential-gated
pipeline and full binary gate below complete with real Apple credentials.

Unreleased process fixes scope watched main/helpers and preset signals to the
current user, pin start-time evidence to UTC, preserve UTF-8 names, and stop
cancelled Open readiness polling. Executable-path identity checks remain in
place. Regression tests use injected inventories for ownership and cancellation;
this does not establish live Fast User Switching or GlobalProtect compatibility.

## Release inputs

Before starting:

1. Confirm the release scope and whether any prior build reached users.
2. Confirm `VERSION`, `BUILD_NUMBER`, and changelog date/notes. Build numbers
   must increase monotonically for every distributed artifact of a version.
3. Confirm the working branch is the default branch, its upstream is known, and
   the worktree contains no unrelated changes.
4. Fetch the remote and stop if history has diverged or the branch is behind in
   a way that cannot be updated by a normal fast-forward/rebase workflow.
5. Inventory the actual macOS versions, architectures, signing identities, and
   managed-product environments available for QA. Missing coverage must be
   stated, not inferred.
6. Review [THREAT_MODEL.md](THREAT_MODEL.md), [PRIVACY.md](PRIVACY.md), and all
   security-sensitive changes since the prior release.

## Canonical automated gate

Run from the repository root on a clean checkout with Xcode 26 or newer:

```bash
for f in script/*.sh; do bash -n "$f" || exit 1; done
swift build -c debug -Xswiftc -warnings-as-errors
swift test
swift test --enable-code-coverage
swift test --scratch-path /tmp/taskscope-release-strict \
  -Xswiftc -warnings-as-errors \
  -Xswiftc -warn-concurrency \
  -Xswiftc -enable-actor-data-race-checks
swift build -c release
./script/test_packaging.sh
git diff --check
```

Record the toolchain (`sw_vers`, `swift --version`, and `xcodebuild -version`)
and the pass/fail result of every command. Do not dismiss a failure as
environmental without reproducing and documenting its cause.

## Manual release QA

Use disposable controlled processes for Stop and Force Stop. Never use a
production workload or managed security daemon merely to exercise a destructive
test.

Record evidence for every locally testable item:

- clean install and upgrade from existing preferences;
- bundle-ID migration behavior where the identifier changes;
- Stop, Force Stop, process exit, PID reuse, selection, and batch reporting;
- watched-app open/close success, absent files, partial failures, and denial;
- Prompt, Auto Stop, and Log Only rules, including queue-head replacement while
  an alert is visible and quick-sheet repair of migration-disabled rules;
- saved-selection recall read failure, background inventory failure/recovery,
  per-user Services badges, and TaskScope self-stop menu/Return protection;
- corrupt settings, presets, rules/events, and saved-selection recovery/reset;
- notification not-determined, allowed, denied, revoked, and recovery states;
- Accessibility denial/grant and exact Activity Monitor PID handoff, including
  consecutive handoffs to different processes before table-state restoration;
- Launch at Login registration, required approval, disable, and recovery;
- hotkey conflict, previous-shortcut restoration, and reserved saved-shortcut
  migration to ⌃⌥⌘T with a Settings notice;
- cold and warm `taskscope://refresh`, plus rejection of every other URL route;
- Shortcuts cold launch without an unintended window or Dock icon, using a real
  eligible signature; Stop confirmation and cancellation from Shortcuts, Siri,
  Spotlight, and App Shortcuts;
- light/dark appearance, keyboard operation, VoiceOver labels, and destructive
  confirmations.

GlobalProtect restoration requires an appropriate managed test machine. If one
is unavailable, test only safe simulations and document the missing external
coverage. Likewise, do not claim macOS 14, Intel, or universal runtime support
without the corresponding machine or VM evidence.

### GlobalProtect compatibility evidence gate

Use **Compatibility Self-Check** on the built-in preset and retain the redacted
export with the tested source revision or artifact identifier. Follow the
matrix and procedure in
[GLOBALPROTECT_COMPATIBILITY.md](GLOBALPROTECT_COMPATIBILITY.md). The export
records actual versions, known optional-agent layout, launchd override/loaded
states, process ownership counts, and protected-service verification. It does
not certify VPN health, policy behavior, or persistence across login/reboot.

Keep fixture tests, live read-only observations, and authorized lifecycle smoke
tests in separate evidence rows. For each claimed GlobalProtect/macOS/CPU
combination, require before/after reports and manual results for Keep Off,
TaskScope relaunch, login/reboot persistence, and Open/restoration. Record any
unknown probe, unexpected label, unverified protected service, or managed-policy
interference as a coverage gap. Do not promote a row to supported on the basis
of a passing parser test or a single snapshot. If no managed lifecycle test was
performed, release notes must explicitly say **GlobalProtect lifecycle
compatibility unverified** and retain the existing source/development scope.

The lifecycle audit fixes have fixture coverage only: background polling preserves
loaded session VPN services, session layouts preserve loaded system daemons and
their overrides with an incomplete-stop report, shutdown/readiness waits use
bounded deadlines, failed agent restoration retains Keep Off intent, and polling
cancellation produces no failure report. Validate these cases on an authorized
managed test machine before claiming live compatibility.

Both public-binary modes of `script/release.sh` enforce the
[machine-checkable evidence contract](GLOBALPROTECT_COMPATIBILITY.md#machine-checkable-release-evidence).
For the exact version/build, retain at least one tracked `.evidence` manifest
under `Evidence/GlobalProtect/lifecycle/<version>-<build>/`. Every manifest must
identify the tested candidate and environment, declare no coverage gaps, record
all nine lifecycle/protected-service/VPN/policy checks as `pass`, and reference
six distinct, nonempty snapshot files plus manual observations. Paths must stay
inside that candidate's evidence directory without symlinks. All candidate
content outside the evidence directory tree and three release documents must
match the tested source revision. Evidence-only follow-up commits are allowed.

Missing, malformed, incomplete, failed, or stale evidence stops preflight and
the full release before build, signing, or notarization. The error names the
missing requirement and links to the collection contract; credentials cannot
bypass it. The current read-only observation and fixtures intentionally fail
this gate. Do not fabricate a passing manifest to unblock packaging: continue
using the source/development flow until authorized lifecycle QA is available.
Machine validation checks explicit attestations and retained files; maintainers
must review their contents and keep compatibility claims within that coverage.

## Local source/development release verification

Stage and verify the current-architecture bundle. Staging stops verified running
copies of the staged app before replacement, including when invoked by the
installer, release pipeline, or packaging tests:

```bash
./script/build_and_run.sh --stage
./script/build_and_run.sh --verify   # verifies the bundle staged above without rebuilding it
codesign --verify --deep --strict dist/build.noindex/TaskScope.app
lipo -archs dist/build.noindex/TaskScope.app/Contents/MacOS/TaskScope
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' dist/build.noindex/TaskScope.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/build.noindex/TaskScope.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' dist/build.noindex/TaskScope.app/Contents/Info.plist
```

Inspect the displayed signature with `codesign -dv --verbose=4`. Record it as
ad-hoc or Apple Development exactly as shown. These checks do not establish
Developer ID distribution trust or notarization.

## Credential-gated public binary pipeline

Run the credential-independent validation with a syntactically valid
non-development candidate identifier and the retained lifecycle evidence above:

```bash
TASKSCOPE_BUNDLE_ID=com.example.TaskScope ./script/release.sh --preflight
```

Preflight validates identifier syntax and rejects the local development prefix;
it does not verify ownership. It also validates version/build, arm64 host/policy,
the GlobalProtect lifecycle evidence contract, and required tools. With the
repository's current unverified lifecycle coverage, this command is expected to
fail with collection instructions. After evidence passes, it reports missing
credentials but does not sign, notarize, or create a releasable artifact.

The evidence regression tests run as part of `script/test_packaging.sh` and can
also run alone with `bash script/test_release_compatibility.sh`. They use only
synthetic files in a disposable Git repository and stub release tools; their
passing results are not installed-product compatibility evidence. Packaging tests
clear inherited packaging and release inputs, so exported production settings
do not change their development defaults.

The full pipeline requires all of these environment variables:

- `TASKSCOPE_BUNDLE_ID`: a non-`com.local.*` production identifier whose
  ownership the maintainer has verified separately;
- `TASKSCOPE_CODE_SIGN_IDENTITY`: an available `Developer ID Application: ...`
  identity with its private key;
- `TASKSCOPE_EXPECTED_TEAM_ID`: the corresponding ten-character Apple Team ID;
- `TASKSCOPE_NOTARY_KEYCHAIN_PROFILE`: an existing `notarytool` keychain
  profile;
- optional `TASKSCOPE_RELEASE_ARCHS=arm64`, whose only accepted value for the
  first release is `arm64`.

With those values configured securely outside Git, run:

```bash
./script/release.sh --release
```

The script requires a clean worktree; validates identifier syntax, version,
build (which must exceed the maximum build number across all `v*` tags,
including prereleases and hotfixes; missing or invalid tagged values fail), the
presence of a `## [<version>]` changelog heading, arm64 architecture, retained
GlobalProtect lifecycle evidence, deployment target, and App Intents metadata; builds
with hardened runtime and no entitlements; verifies the Developer ID team;
creates matching app/dSYM UUIDs; submits to Apple; staples and
Gatekeeper-verifies the app; round-trips the final ZIP; and emits the app ZIP,
dSYM ZIP, notary result, provenance, and verified `SHA256SUMS` under
`dist/releases/`.

Successful script output is necessary but does not prove bundle-identifier
ownership, migrate preferences or permissions, or replace manual clean-machine,
upgrade, cross-version, and managed-product QA. A failed or unrun credentialed
pipeline is not evidence of signing or notarization.

## Additional gate for a public binary

A public app archive, ZIP, DMG, or installer is allowed only after all of these
are true:

1. An owned production bundle identifier is configured consistently throughout
   build, install, logs, URL registration, App Intents, and login items.
2. Existing preference/permission identity is migrated and upgrade-tested, or
   the release clearly documents a deliberate break before installation.
3. The architecture policy is explicit. A universal claim is verified with
   `lipo -archs`; an arm64-only artifact is labeled arm64 everywhere.
4. Hardened runtime and any entitlements have been reviewed and verified from
   the signed artifact.
5. The app is signed with an authorized **Developer ID Application** identity
   and a secure timestamp. No certificate or credential is stored in Git.
6. Apple notarization succeeds for the exact archive and its ticket is stapled
   where the artifact format supports stapling.
7. `codesign`, `spctl`, and `stapler validate` succeed against the final copy.
8. A SHA-256 checksum is produced after all signing/notarization/stapling and is
   published alongside the artifact.
9. Install, first launch, Shortcuts, URL refresh, permissions, upgrade, and
   uninstall succeed on a clean machine using the downloaded copy.
10. The GlobalProtect lifecycle evidence gate passes for the candidate, and
    reviewers confirm the retained observations support every advertised
    environment and lifecycle claim.

Never print or commit credential values. If an Apple certificate, notary
credential, paid enrollment, owned identifier, or test machine is missing,
finish all credential-independent checks and label the release source only.

## Commit, tag, and publish

1. Review the complete diff and rerun the gate after the final change.
2. Commit the release preparation to the default branch with a descriptive
   message and push normally. Never force-push or rewrite public history.
3. Verify the pushed commit is the intended release commit and confirm the
   recorded local gate output (see "Canonical automated gate") passed for that
   exact commit. There are no hosted checks.
4. Create `v<version>` at that exact commit. Use the repository's configured
   signed-tag mechanism; if no signing mechanism exists, do not claim the tag is
   signed.
5. Push the tag normally.
6. Publish a GitHub release using the changelog, explicitly identifying it as
   source/development-only when the public binary gate was not completed.
7. Verify the release page, tag target, source archives, notes, and every link
   from a clean or logged-out context as visibility permits.
8. Confirm `git status -sb` is clean and synchronized.

Do not publish a release link in prose as evidence before the release exists.

## Installation rollback

`script/install.sh` copies to a temporary bundle, preserves the prior
installation, verifies the replacement, and restores the backup if replacement
fails. `script/test_packaging.sh` injects failures before and after replacement
to exercise that transaction.

If an installed development build must be downgraded after a successful
install:

1. Export readable presets and preserve needed preference data.
2. Turn off Launch at Login and quit TaskScope.
3. Install the previously verified app bundle through the same transactional
   installer or restore a known-good backup.
4. Do not downgrade preferences across an incompatible schema unless migration
   tests prove it safe.
5. Reverify signature, version/build, startup, URL refresh, Shortcuts, and
   permissions.

## Published-release rollback

Never move an existing tag to another commit. For a defective release:

1. Mark the GitHub release and artifact status clearly; remove a dangerous
   binary from download if necessary without erasing the tag/history.
2. Open a private security advisory first when disclosure itself creates risk.
3. Prepare a higher patch version from the last safe commit, with a build number
   greater than every existing `v*` tag, including other release lines.
4. Run the full gate and publish a new immutable tag/release.
5. Explain affected versions, mitigation, preference compatibility, and upgrade
   instructions without exposing unresolved exploit details.

After publication, monitor issues without asking users to expose private process
or organization data. Release follow-up belongs in [ROADMAP.md](ROADMAP.md).
