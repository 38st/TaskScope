#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/taskscope-release-evidence.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

FIXTURE_DIR="$TEST_DIR/release fixture"
FAKE_BIN="$TEST_DIR/bin"
TOOL_LOG="$TEST_DIR/tool-calls"
OUTPUT="$TEST_DIR/output"
EVIDENCE_RELATIVE='Evidence/GlobalProtect/lifecycle/1.2.3-7'
EVIDENCE_DIR="$FIXTURE_DIR/$EVIDENCE_RELATIVE"
MANIFEST="$EVIDENCE_DIR/arm64.evidence"
CHECKS=0
mkdir -p "$FIXTURE_DIR/script" "$FIXTURE_DIR/Sources" "$EVIDENCE_DIR" "$FAKE_BIN"
cp "$ROOT_DIR/script/release.sh" "$ROOT_DIR/script/packaging_common.sh" "$FIXTURE_DIR/script/"
printf '1.2.3\n' > "$FIXTURE_DIR/VERSION"
printf '7\n' > "$FIXTURE_DIR/BUILD_NUMBER"
printf '## [1.2.3] - 2026-09-26\n' > "$FIXTURE_DIR/CHANGELOG.md"
printf 'tested candidate\n' > "$FIXTURE_DIR/Sources/candidate.txt"
git init -q -b main "$FIXTURE_DIR"
git -C "$FIXTURE_DIR" config user.name 'Packaging Tests'
git -C "$FIXTURE_DIR" config user.email 'packaging-tests@example.invalid'
git -C "$FIXTURE_DIR" config commit.gpgsign false
git -C "$FIXTURE_DIR" config core.hooksPath /dev/null
git -C "$FIXTURE_DIR" add .
git -C "$FIXTURE_DIR" commit -qm 'Synthetic candidate; not compatibility evidence'
TESTED_REVISION="$(git -C "$FIXTURE_DIR" rev-parse HEAD)"

# Tool discovery is allowed only after evidence passes. Any attempted build,
# signing, or notary operation is a test failure, without using credentials.
cat > "$FAKE_BIN/release-tool" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$TOOL_LOG"
[[ "${0##*/}" == xcrun && "${1:-}" == --find ]] && exit 0
exit 91
EOF
chmod +x "$FAKE_BIN/release-tool"
for tool in codesign ditto dwarfdump lipo plutil security shasum shlock spctl swift xcodebuild xcrun; do
  ln -s release-tool "$FAKE_BIN/$tool"
done

run_release() {
  : > "$TOOL_LOG"
  (
    unset TASKSCOPE_CODE_SIGN_IDENTITY TASKSCOPE_EXPECTED_TEAM_ID TASKSCOPE_NOTARY_KEYCHAIN_PROFILE
    cd "$TEST_DIR" # The gate must resolve evidence independently of the caller cwd.
    TASKSCOPE_BUNDLE_ID=com.example.TaskScopeTests TASKSCOPE_RELEASE_ARCHS=arm64 \
      TOOL_LOG="$TOOL_LOG" PATH="$FAKE_BIN:$PATH" \
      bash "$FIXTURE_DIR/script/release.sh" "$@"
  ) > "$OUTPUT" 2>&1
}

assert_failure() {
  local expected="$1"
  local mode="${2:---preflight}"
  if run_release "$mode"; then
    echo "Release $mode unexpectedly accepted: $expected" >&2
    cat "$OUTPUT" >&2
    exit 1
  fi
  for message in "$expected" 'GlobalProtect lifecycle compatibility unverified' \
    'GLOBALPROTECT_COMPATIBILITY.md#machine-checkable-release-evidence' 'source/development-only'; do
    if ! grep -Fq -- "$message" "$OUTPUT"; then
      echo "Release rejection did not explain: $message" >&2
      cat "$OUTPUT" >&2
      exit 1
    fi
  done
  if [[ -s "$TOOL_LOG" || -e "$FIXTURE_DIR/dist" ]]; then
    echo "Rejected evidence caused release-tool or artifact side effects." >&2
    cat "$TOOL_LOG" >&2
    exit 1
  fi
  CHECKS=$((CHECKS + 1))
}

assert_success() {
  if ! run_release --preflight; then
    cat "$OUTPUT" >&2
    exit 1
  fi
  for message in 'GlobalProtect lifecycle evidence gate passed' \
    'Credential-independent release preflight passed.' 'Full release still requires TASKSCOPE_CODE_SIGN_IDENTITY.'; do
    grep -Fq "$message" "$OUTPUT" || { cat "$OUTPUT" >&2; exit 1; }
  done
  if grep -v '^xcrun --find ' "$TOOL_LOG" | grep -q . || [[ -e "$FIXTURE_DIR/dist" ]]; then
    echo "Preflight attempted a build, credential, or artifact operation." >&2
    exit 1
  fi
  CHECKS=$((CHECKS + 1))
}

set_field() {
  local key="$1"
  local value="$2"
  awk -v key="$key" -v value="$value" 'index($0, key "=") == 1 { $0 = key "=" value } { print }' \
    "$MANIFEST" > "$TEST_DIR/changed"
  mv "$TEST_DIR/changed" "$MANIFEST"
}

reset_manifest() {
  cp "$TEST_DIR/valid.evidence" "$MANIFEST"
}

assert_failure 'No lifecycle manifests found'
assert_failure 'No lifecycle manifests found' --release
assert_failure 'No lifecycle manifests found' release
assert_failure 'No lifecycle manifests found' preflight

cat > "$MANIFEST" <<EOF
schema_version=1
evidence_kind=authorized-lifecycle
test_date=2026-09-26
taskscope_version=1.2.3
taskscope_build=7
source_revision=$TESTED_REVISION
bundle_id=com.example.TaskScopeTests
signing_kind=ad-hoc
install_method=staged-bundle
macos_version=26.6.2
macos_build=25G83
architecture=arm64
globalprotect_version=6.3.3-1121
agent_layout=pangpa-and-pangps
persistence_event=logout-login
coverage_gaps=none
manual_results=$EVIDENCE_RELATIVE/manual.md
EOF
printf 'Synthetic manual results; never product evidence.\n' > "$EVIDENCE_DIR/manual.md"
for step in baseline keep_off relaunch persistence keep_off_disabled open protected_service vpn managed_policy; do
  printf 'result_%s=pass\n' "$step" >> "$MANIFEST"
done
for step in baseline keep_off relaunch persistence keep_off_disabled open; do
  printf 'report_%s=%s/%s.txt\n' "$step" "$EVIDENCE_RELATIVE" "$step" >> "$MANIFEST"
  printf 'Synthetic %s snapshot; never product evidence.\n' "$step" > "$EVIDENCE_DIR/$step.txt"
done
cp "$MANIFEST" "$TEST_DIR/valid.evidence"
git -C "$FIXTURE_DIR" add Evidence
assert_success

set_field agent_layout pangpa-only
set_field persistence_event reboot
set_field signing_kind apple-development
set_field install_method local-install
assert_success
set_field signing_kind developer-id
set_field install_method downloaded-archive
assert_success
reset_manifest

# Every required field is required independently; every lifecycle result must
# be pass. Historical snapshots and fixture-only records are never sufficient.
while IFS='=' read -r key value; do
  awk -v key="$key" 'index($0, key "=") != 1' "$TEST_DIR/valid.evidence" > "$MANIFEST"
  assert_failure "Missing required field: $key"
done < "$TEST_DIR/valid.evidence"
reset_manifest
for step in baseline keep_off relaunch persistence keep_off_disabled open protected_service vpn managed_policy; do
  for result in fail not-tested unknown; do
    set_field "result_$step" "$result"
    assert_failure "result_$step must be pass"
  done
  reset_manifest
done

while IFS='=' read -r key value; do
  set_field "$key" "$value"
  assert_failure "$key must "
  reset_manifest
done <<'EOF'
schema_version=2
evidence_kind=fixture
evidence_kind=live-read-only
test_date=unknown
taskscope_version=1.2.4
taskscope_build=8
source_revision=abc123
bundle_id=com.example.Other
signing_kind=unknown
install_method=unknown
macos_version=unknown
macos_build=unknown
architecture=x86_64
globalprotect_version=unknown
agent_layout=unknown
persistence_event=not-tested
coverage_gaps=policy-interference
coverage_gaps=unverified-protected-service
EOF

printf 'result_open=pass\n' >> "$MANIFEST"
assert_failure 'Duplicate field: result_open'
reset_manifest
printf 'unexpected=value\n' >> "$MANIFEST"
assert_failure 'unknown field or malformed'
reset_manifest
printf 'malformed record\n' >> "$MANIFEST"
assert_failure 'unknown field or malformed'
reset_manifest
set_field result_open ''
assert_failure 'result_open must be a nonempty value'
reset_manifest
set_field result_open 'pass '
assert_failure 'result_open must be a nonempty value without whitespace'
reset_manifest

set_field source_revision 0000000000000000000000000000000000000000
assert_failure 'must be an existing ancestor of HEAD'
reset_manifest
printf 'untested change\n' >> "$FIXTURE_DIR/Sources/candidate.txt"
assert_failure 'Candidate content differs from tested source_revision'
git -C "$FIXTURE_DIR" add Sources
assert_failure 'Candidate content differs from tested source_revision'
git -C "$FIXTURE_DIR" restore --source=HEAD --staged --worktree Sources

set_field report_open "$EVIDENCE_RELATIVE/baseline.txt"
assert_failure 'Each lifecycle snapshot needs a distinct report path'
reset_manifest
set_field report_open '/tmp/outside.txt'
assert_failure 'must be retained under'
reset_manifest
set_field report_open "$EVIDENCE_RELATIVE/../outside.txt"
assert_failure 'Invalid evidence path'
reset_manifest
set_field report_open "$EVIDENCE_RELATIVE/missing.txt"
assert_failure 'Missing, unreadable, or empty evidence file'
reset_manifest
: > "$EVIDENCE_DIR/open.txt"
assert_failure 'Missing, unreadable, or empty evidence file'
git -C "$FIXTURE_DIR" restore --worktree "$EVIDENCE_RELATIVE/open.txt"
mv "$EVIDENCE_DIR/open.txt" "$TEST_DIR/snapshot.txt"
ln -s "$TEST_DIR/snapshot.txt" "$EVIDENCE_DIR/open.txt"
assert_failure 'Evidence must not use symlinks'
rm "$EVIDENCE_DIR/open.txt"
mv "$TEST_DIR/snapshot.txt" "$EVIDENCE_DIR/open.txt"
ln -s "$EVIDENCE_DIR" "$EVIDENCE_DIR/link"
set_field report_open "$EVIDENCE_RELATIVE/link/open.txt"
assert_failure 'Evidence must not use symlinks'
rm "$EVIDENCE_DIR/link"
reset_manifest
git -C "$FIXTURE_DIR" rm -q --cached "$EVIDENCE_RELATIVE/open.txt"
assert_failure 'Evidence file is not tracked'
git -C "$FIXTURE_DIR" add Evidence
git -C "$FIXTURE_DIR" rm -q --cached "$EVIDENCE_RELATIVE/arm64.evidence"
assert_failure 'Evidence file is not tracked'
git -C "$FIXTURE_DIR" add Evidence

# A valid environment must not hide another environment with coverage gaps.
cp "$MANIFEST" "$EVIDENCE_DIR/other.evidence"
printf 'result_open=fail\n' >> "$EVIDENCE_DIR/other.evidence"
git -C "$FIXTURE_DIR" add Evidence
assert_failure 'result_open must be pass'
cp "$MANIFEST" "$EVIDENCE_DIR/other.evidence"
git -C "$FIXTURE_DIR" add Evidence
assert_success

# Retaining evidence in a subsequent commit does not invalidate the tested
# source revision. A later code commit does, even with the same version/build.
git -C "$FIXTURE_DIR" commit -qm 'Retain synthetic evidence only'
assert_success
printf 'untested committed change\n' >> "$FIXTURE_DIR/Sources/candidate.txt"
git -C "$FIXTURE_DIR" add Sources
git -C "$FIXTURE_DIR" commit -qm 'Change candidate without retesting'
assert_failure 'Candidate content differs from tested source_revision'
assert_failure 'Candidate content differs from tested source_revision' --release

echo "Release compatibility evidence tests passed ($CHECKS cases)."
