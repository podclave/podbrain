---
description: Verify the team-brain connection, or configure it (including per-project multi-brain setups)
allowed-tools: Bash, Read, Write, Edit
---

# team-brain setup

Help the user get this plugin connected to their team brain. The plugin's skill
is `team-brain`; its `brain.py` lives in that skill's base directory (announced
when the skill loads). Work through these in order:

1. **Check current state.** Run `python3 <skill base dir>/brain.py health`.
   - Healthy JSON → report "connected" plus the brain URL from the SessionStart
     context, and stop unless the user wants multi-brain setup (step 4).
   - A `set BRAIN_URL and BRAIN_SECRET` error → the plugin is unconfigured; go to 2.
   - Any other error → diagnose with the user (URL typo? secret rotated? brain down?).
2. **Single-brain configure (the normal case).** Tell the user to run:
   `claude plugin install team-brain@podbrain --config brain_url=<URL> --config brain_secret=<SECRET>`
   (works on an already-installed plugin; values also settable interactively via
   `/plugin` → team-brain → configure). If the plugin was newly installed, it also needs `claude plugin enable team-brain@podbrain` (with `-s project` for project-scope installs) — install alone is inert by design. Then restart the session and re-run step 1.
3. **Heads-up on scope.** If the plugin is enabled at USER scope, hooks capture
   in EVERY project on this machine. If that's not what the user wants, suggest
   project-scope enablement: `claude plugin install team-brain@podbrain -s project`
   from each project that should be connected.
4. **Multi-brain (different brains per project).** Do NOT use `--config` for
   secrets in this mode (global keychain entries override per-project settings).
   If a secret was previously set via step 2, delete the team-brain@podbrain
   entry from `pluginSecrets` in `~/.claude/.credentials.json` first — that
   leftover global secret silently overrides every per-project one.
   Instead, in each project write `.claude/settings.local.json`:

   ```json
   { "pluginConfigs": { "team-brain@podbrain": { "options": {
       "brain_url": "https://that-projects-brain.sprites.app",
       "brain_secret": "<that brain's secret>" } } } }
   ```

   Merge carefully if the file exists. Confirm the file is git-ignored (add it to
   .gitignore if not). Then restart the session and verify with step 1 — and check
   the SessionStart context names the RIGHT brain.
5. Optional: `BRAIN_NO_DISTILL=1` in the environment keeps auto-recall but turns
   off passive capture, if the user wants recall-only.
6. **Removing.** `claude plugin disable team-brain@podbrain -s <scope>` first, then
   `claude plugin uninstall team-brain@podbrain` (uninstall refuses while enabled
   at project scope). Uninstall also removes the stored config and secret.
