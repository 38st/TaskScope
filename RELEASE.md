# Release and Rollback Guide

This is the maintainer runbook for producing an honest TaskScope release. A
release is complete only when its tag, notes, artifacts, and documented claims
match independently verified evidence. A changelog entry, local install, or
staged app is not itself a published release.

## Current 1.0.0 scope

- Version: `1.0.0`
- Build: `3` (the 1.0.0 tag carries build `2`; `script/release.sh` refuses a
  build number that is not greater than the latest `v*` tag's)
- Deployment target: macOS 14
- Verified packaging architecture: arm64 only
- Distribution: GitHub source release and local-development packaging
- Local bundle identifier: `com.local.TaskScope`
- Possible local signatures: Apple Development or ad-hoc
- Not provided or claimed: production bundle identity, universal/Intel binary,
  Developer ID signature, hardened-runtime review, notarization, stapling, or a
  public downloadable app bundle

Do not attach `dist/TaskScope.app` or an archive of it to the GitHub 1.0.0
source release as a production binary. GitHub's generated source archives are
the only release artifacts within this scope unless the credential-gated
pipeline and full binary gate below complete with real Apple credentials.

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
bash -n script/*.sh
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
- Prompt, Auto Stop, and Log Only rules;
- corrupt settings, presets, rules/events, and saved-selection recovery/reset;
- notification not-determined, allowed, denied, revoked, and recovery states;
- Accessibility denial/grant and exact Activity Monitor PID handoff;
- Launch at Login registration, required approval, disable, and recovery;
- hotkey conflict and previous-shortcut restoration;
- cold and warm `taskscope://refresh`, plus rejection of every other URL route;
- Shortcuts cold launch without an unintended window, using a real eligible
  signature;
- light/dark appearance, keyboard operation, VoiceOver labels, and destructive
  confirmations.

GlobalProtect restoration requires an appropriate managed test machine. If one
is unavailable, test only safe simulations and document the missing external
coverage. Likewise, do not claim macOS 14, Intel, or universal runtime support
without the corresponding machine or VM evidence.

## Local source/development release verification

Stage and verify the current-architecture bundle:

```bash
./script/build_and_run.sh --stage
./script/build_and_run.sh --verify   # verifies the bundle staged above without rebuilding it
codesign --verify --deep --strict dist/TaskScope.app
lipo -archs dist/TaskScope.app/Contents/MacOS/TaskScope
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' dist/TaskScope.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/TaskScope.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' dist/TaskScope.app/Contents/Info.plist
```

Inspect the displayed signature with `codesign -dv --verbose=4`. Record it as
ad-hoc or Apple Development exactly as shown. These checks do not establish
Developer ID distribution trust or notarization.

## Credential-gated public binary pipeline

Run the credential-independent validation with a syntactically valid
non-development candidate identifier:

```bash
TASKSCOPE_BUNDLE_ID=com.example.TaskScope ./script/release.sh --preflight
```

Preflight validates identifier syntax and rejects the local development prefix;
it does not verify ownership. It also validates version/build, arm64 host/policy,
and required tools. It reports missing credentials but does not sign, notarize,
or create a releasable artifact.

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
build (which must exceed the build number at the latest `v*` tag), the
presence of a `## [<version>]` changelog heading, arm64 architecture,
deployment target, and App Intents metadata; builds
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
3. Prepare a higher patch version and build number from the last safe commit.
4. Run the full gate and publish a new immutable tag/release.
5. Explain affected versions, mitigation, preference compatibility, and upgrade
   instructions without exposing unresolved exploit details.

After publication, monitor issues without asking users to expose private process
or organization data. Release follow-up belongs in [ROADMAP.md](ROADMAP.md).
