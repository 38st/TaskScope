# Support and Recovery

TaskScope is currently distributed as source with local-development packaging.
There is no guaranteed support response time and no published production binary
support channel.

## Before requesting help

Record:

- the exact version and build from About TaskScope;
- macOS version and Mac architecture;
- whether the app was source-built, ad-hoc signed, Apple Development-signed, or
  obtained from a published release;
- the failing action and its exact user-visible result;
- whether notification, Accessibility, login-item, or built-in GlobalProtect
  administrator approval was denied.

Sanitize all logs and screenshots. Process names, commands, usernames, app and
plist paths, job labels, ports, and organization details can be sensitive.

Use a GitHub bug report for a reproducible non-security defect. Do not use a
public issue for a vulnerability or private conduct report; follow
[SECURITY.md](SECURITY.md) and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Common recovery steps

### App will not start or Shortcuts cannot discover actions

1. Run `./script/build_and_run.sh --verify` from the source checkout.
2. Verify the installed app, not the bare SwiftPM executable, is being launched.
3. An ad-hoc signature cannot execute TaskScope App Intents. Rebuild with an
   eligible Apple Development identity for local Shortcuts testing.
4. Reinstall using `./script/install.sh`, launch once, and retry Shortcuts.

These steps do not make the app Developer ID-signed or notarized.

### Process information is unavailable

TaskScope relies on local macOS process tools. Retry after refreshing. If the
inventory remains unavailable, record the exact in-app error rather than
assuming that no process is running. Extended network/disk counters can be
unavailable independently of the basic process list.

### Activity Monitor opens but does not select the PID

Allow TaskScope in **System Settings > Privacy & Security > Accessibility**, then
retry. If access is intentionally denied, Activity Monitor can still open but
exact selection is unavailable. When exact selection temporarily changes the
Activity Monitor search, process scope, or PID column, TaskScope restores the
prior state after a short handoff delay.

### Notifications do not appear

Enable notifications inside TaskScope and allow TaskScope in macOS Notification
settings. If access was denied or revoked, use the Settings recovery link and
retry only after macOS reports permission as allowed. Enabling a watched preset
does not imply global notification authorization.

### Launch at Login needs approval

Open TaskScope Settings, inspect its login-item status, and follow the macOS
Login Items recovery link. Disable and re-enable only after the current state is
visible. During uninstall, disable Launch at Login before deleting the app.

### Stored data is unreadable

TaskScope preserves unreadable payloads under a preference key ending in
`.corruptBackup` and prevents some affected stores from overwriting the primary
data. Preserve the named backup before selecting a destructive reset. Do not
export an empty fallback list as a backup. Reset resumes persistence with the
currently recovered in-memory state where supported.

Legacy name-only Auto Stop rules are retained but disabled. Add and verify the
intended absolute executable path before enabling automatic stopping.

### A watched-app lifecycle partially fails

Read the per-job lifecycle report. Missing app/plist paths and user launch-agent
failures apply to custom presets. Administrator denial and managed-service
policy apply only to the immutable built-in GlobalProtect daemon-restoration
path. Do not repeat that privileged operation blindly; use the organization's
managed installer or IT support when its protected service cannot be restored.

### GlobalProtect keeps reopening

Use **Keep GlobalProtect Off** on the built-in preset instead of repeatedly
killing its window. The control disables and unloads the known per-user
`pangpa` and, when installed, `pangps` launch agents. It persists across login.
Choosing **Open** or turning the control off re-enables those user agents. A
protected system `PanGPS` launch daemon remains outside this control; if policy
or management software restores user agents, consult the organization managing
the Mac.

## Export and upgrade precautions

Export readable watched presets before a risky upgrade. The current development
bundle identifier is `com.local.TaskScope`; changing to a production identifier
changes the preferences, permissions, Shortcuts, URL, and login-item identity.
Do not assume local development state migrates until the release explicitly says
that migration was tested.

## Uninstall and erase local data

1. Turn off Launch at Login.
2. Quit TaskScope.
3. Delete the app bundle.
4. Remove Accessibility and notification permission entries if desired.
5. For the current development identifier only, erase preferences with:

   ```bash
   defaults delete com.local.TaskScope
   ```

The final step is permanent and removes settings, presets, rules, saved
selections, event history, and corruption backups. A production release with a
different identifier requires its own documented deletion command.
