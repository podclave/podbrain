# Client config bundle

The team-brain client ships as a **Podclave config bundle** — 4 overlay files,
no installer. Add these to the `team-brain` bundle. Relative paths
land in `$HOME`; `.env.podclave.*` is auto-sourced into every shell; `brain.sh`
is always invoked via `bash …`, so no executable bit is needed.

| # | Overlay path | Owner | Contents = repo file |
|---|---|---|---|
| 1 | `.claude/skills/team-brain/SKILL.md` | user | `client/skills/team-brain/SKILL.md` |
| 2 | `.claude/skills/team-brain/brain.sh` | user | `client/skills/team-brain/brain.sh` |
| 3 | `.env.podclave.brain` | user | fill from `client/env.podclave.brain.template` |
| 4 | `/etc/claude-code/managed-settings.d/20-team-brain.json` | root | `client/managed-settings.d/20-team-brain.json` |

## Notes

- **#3 is the only file with secrets** — its real contents live in Podclave, not
  git. Identical for the whole org:
  ```sh
  export BRAIN_URL="https://<brain>.sprites.app"
  export BRAIN_SECRET="<secret>"
  ```
- **Identity is not in the bundle.** `brain.sh` reads `~/.podclave/user-email`
  (written by Podclave on Setup), falling back to git email / `$USER`. So all 4
  overlays are byte-identical for everyone, yet attribution is per-person.
- **#4 is `owner: root`** so users can't disable the hooks. Claude Code *combines*
  hooks across all settings sources, so this file adds the auto-recall +
  auto-capture hooks **without touching anyone's own `~/.claude/settings.json`**.
- `brain.sh` is a single file containing everything: the `recall` / `remember` /
  `file` / `health` subcommands the skill calls, plus the `hook-recall` /
  `hook-stop` / `hook-sessionend` / `distill` subcommands the hooks call.

See [../docs/ROLLOUT.md](../docs/ROLLOUT.md) for the full rollout (server, schedule, verification).
