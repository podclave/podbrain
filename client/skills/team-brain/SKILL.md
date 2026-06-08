---
name: team-brain
description: THE memory system for this machine. Use it whenever the user asks to remember/save/note something, asks "what do we know about…" / "did we decide…" / to recall or look something up, or says "file this" about a document — and proactively recall before non-trivial work. There is no other memory; native auto-memory is disabled. Memory lives in the shared team brain, reached through the agentmemory MCP tools.
---

# Team Brain — the memory system

This is the **single source of truth for memory** on this machine. Native Claude
auto-memory is disabled org-wide; **all** remembering and recalling goes through the
shared team brain, so knowledge compounds across the whole team. The brain is
exposed as the **`agentmemory` MCP** (tools named `mcp__agentmemory__memory_*`),
pointed at the team's central server.

## Always use it for
- **Recall / "what do we know about…" / "did we decide…" / look something up** → `memory_smart_search` (hybrid search) or `memory_recall`.
- **Remember / save / "note that" / "don't forget"** → `memory_save` (one atomic, self-contained fact per call).
- **Curate / dedupe / "clean those up"** → inspect with `memory_smart_search`, then `memory_governance_delete` to remove duplicates (this prompts — it's shared, irreversible state). Use `memory_snapshot_create` first if you want an explicit restore point, `memory_consolidate` to run the consolidation pipeline, and `memory_audit` to see what changed.
- **"file this" / a document to absorb (PRD, deck, PDF, docx, md)** → `python3 ~/.claude/skills/team-brain/brain.py file "<path>" "<optional note>"`. This is the ONE thing not in the MCP: it uploads the document to the brain's ingest endpoint, which extracts + chunks + stores it so its contents become searchable via the MCP.
- **"open the memory viewer" / "show me the dashboard" / "browse the brain in a browser"** → `python3 ~/.claude/skills/team-brain/brain.py viewer`. Prints a ready-to-open URL (`<brain>/viewer?key=…`) that logs the browser in via a cookie; give the user the URL to click. The key is embedded by design (admin/ops-grade access to the shared dashboard).
- **Proactively**: `memory_smart_search` for relevant prior decisions / conventions / gotchas before non-trivial work on a shared project.

## Conventions
- Memory means the team brain — never write to or create a local `MEMORY.md`/memory file; never tell the user you've saved something unless it went to the brain (via the MCP).
- Keep saved facts **atomic and self-contained** — one fact per `memory_save`.
- The brain supersedes near-duplicate saves automatically (keeping the newer phrasing), so prefer a clear, specific re-statement over worrying about exact-match dupes; reach for `memory_governance_delete` only for genuinely redundant records.
- Relevant knowledge is also auto-injected each turn inside `<team-brain-context>` (the recall hook); use `memory_smart_search` explicitly for deeper or query-specific lookups.
- Destructive curation (`memory_governance_delete`) acts on **shared, team-wide** memory and will prompt — confirm scope with the user before bulk deletes.
