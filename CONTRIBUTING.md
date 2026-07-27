# Contributing to TaskScope

Thanks for helping improve TaskScope.

## Before opening an issue

- Search existing issues and discussions for the same behavior.
- Use the bug report template for reproducible defects.
- Do not include private process lists, command lines, organization names, or
  other machine-specific data in public reports.
- Report security issues privately as described in [SECURITY.md](SECURITY.md).

## Development workflow

TaskScope requires macOS 14 or newer. Swift tools 5.9 or newer can build the
app; Xcode 26 or newer is required to compile the current UI test dependency,
run the full test suite, and package App Intents metadata.

1. Fork and clone the repository.
2. Create a focused branch from `main`.
3. Make the smallest coherent change and add regression coverage where useful.
4. Run the local quality gate:

   ```bash
   bash -n script/*.sh
   swift build -c debug -Xswiftc -warnings-as-errors
   swift test
   swift build -c release
   ./script/test_packaging.sh
   ```

5. Open a pull request using the repository template.

Keep pull requests focused. Explain user-visible behavior changes and call out
anything that affects process signaling, privileged lifecycle operations,
permissions, persistence, packaging, or automation.

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
