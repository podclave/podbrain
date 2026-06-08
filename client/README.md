# Client config bundle

The team-brain client ships as a **Podclave config bundle** — 5 overlay files,
no installer. Add these to the `team-brain` bundle. Relative paths
land in `$HOME`; `.env.podclave.*` is auto-sourced into every shell; `brain.py`
is always invoked via `python3 …` (stdlib only — no pip), so no executable bit is needed.

| # | Overlay path | Owner | Contents = repo file |
|---|---|---|---|
| 1 | `.claude/skills/team-brain/SKILL.md` | user | `client/skills/team-brain/SKILL.md` |
| 2 | `.claude/skills/team-brain/brain.py` | user | `client/skills/team-brain/brain.py` |
| 3 | `.env.podclave.brain` | user | fill from `client/env.podclave.brain.template` |
| 4 | `/etc/claude-code/managed-settings.d/20-team-brain.json` | root | `client/managed-settings.d/20-team-brain.json` |
| 5 | `/etc/claude-code/managed-mcp.json` | root | `client/managed-mcp.json` |

## Notes

- **#3 is the only file with secrets** — its real contents live in Podclave, not
  git. Identical for the whole org:
  ```sh
  export BRAIN_URL="https://<brain>.sprites.app"
  export BRAIN_SECRET="<secret>"
  ```
- **Identity is not in the bundle.** `brain.py` reads `~/.podclave/user-email`
  (written by Podclave on Setup), falling back to git email / `$USER`. So all
  overlays are byte-identical for everyone, yet attribution is per-person.
- **#4 is `owner: root`** so users can't disable the hooks. Claude Code *combines*
  hooks across all settings sources, so this file adds the auto-recall +
  auto-capture hooks **without touching anyone's own `~/.claude/settings.json`**.
  It also carries the `permissions.allow` set that auto-approves the safe
  agentmemory MCP tools (read + reversible curation); destructive ops
  (`memory_governance_delete`) and the agent-workflow tools are left to prompt.
- **#5 is the agentmemory MCP** (`owner: root`). It points each teammate's Claude
  at the shared brain via a local `npx @agentmemory/mcp` stdio shim in **proxy
  mode** (`AGENTMEMORY_FORCE_PROXY=1` + `${BRAIN_URL}`/`${BRAIN_SECRET}`), so the
  agent gets the full native memory toolset (search/save/curate/snapshot/audit).
  A managed `managed-mcp.json` takes **exclusive** control of MCP — it becomes the
  only MCP allowed fleet-wide (add any other team MCP to that file);
  `allowAllClaudeAiMcps` keeps users' claude.ai connectors. Needs **node** on the
  client (the shim) and Claude Code **≥ 2.1.149**.
- **`brain.py`'s role is now narrow**: the deterministic **hooks** (auto-recall +
  passive distillation — shell hooks can't call MCP tools) and the **`file`**
  document-ingest verb (a gateway-only endpoint, not in the engine MCP).
  Interactive memory (recall/save/curate) is the **MCP**, not `brain.py`.

See [../docs/ROLLOUT.md](../docs/ROLLOUT.md) for the full rollout (server, schedule, verification).
