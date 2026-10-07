## Summary

Describe the problem and the change.

## Validation

- [ ] `for f in script/*.sh; do bash -n "$f" || exit 1; done`
- [ ] `swift build -c debug -Xswiftc -warnings-as-errors`
- [ ] `swift test`
- [ ] `swift test --enable-code-coverage`
- [ ] `swift test --scratch-path /tmp/taskscope-release-strict -Xswiftc -warnings-as-errors -Xswiftc -warn-concurrency -Xswiftc -enable-actor-data-race-checks`
- [ ] `swift build -c release`
- [ ] `./script/test_packaging.sh`
- [ ] `git diff --check`

Explain any check that does not apply or could not run.

## Risk

Call out changes to process signaling, privileged lifecycle operations,
permissions, persistence, packaging, or automation. Write `None` if none apply.
