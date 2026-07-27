# Security Policy

## Supported versions

Security fixes are made on the latest release and the `main` branch.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability.

Use **Report a vulnerability** on the repository's GitHub Security tab to send
a private report. Include the affected version, macOS version, impact, and
minimal reproduction steps. Remove usernames, organization details, process
command lines, and other machine-specific data unless they are essential to
the report.

If private vulnerability reporting is temporarily unavailable, contact the
maintainer through the GitHub profile without publishing exploit details.

You should receive an acknowledgment within seven days. Confirmed issues will
be coordinated privately until a fix and disclosure plan are ready.

## Security-sensitive behavior

TaskScope can send signals to user processes and can request administrator
approval when restoring explicitly configured system launch daemons. It does
not bypass macOS authorization. Treat imported watched-app presets as
configuration from a trusted source and review their paths, labels, process
names, and ports before using lifecycle actions.
