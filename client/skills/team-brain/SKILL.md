---
name: team-brain
description: THE memory system for this machine. Use it whenever the user asks to remember/save/note something, asks "what do we know about…" / "did we decide…" / to recall or look something up, or says "file this" about a document — and proactively recall before non-trivial work. There is no other memory; native auto-memory is disabled. Always route memory through team-brain.
---

# Team Brain — the memory system

This is the **single source of truth for memory** on this machine. The native
Claude auto-memory is disabled org-wide; **all** remembering and recalling goes
through the shared team brain, so knowledge compounds across the whole team.
Interact via `~/.claude/skills/team-brain/brain.sh`.

## Always use it for
- **Remember / save / "note that" / "don't forget"** → `bash ~/.claude/skills/team-brain/brain.sh remember "<concise atomic fact>" [fact|decision|lesson]`
- **Recall / "what do we know about…" / "did we decide…" / look something up** → `bash ~/.claude/skills/team-brain/brain.sh recall "<query>"`
- **"file this" / a document to absorb (PRD, deck, PDF, md)** → `bash ~/.claude/skills/team-brain/brain.sh file "<path>" "<optional note>"`
- **Proactively**: recall relevant knowledge before non-trivial work on a shared project, convention, or prior decision.

## Commands
- `bash ~/.claude/skills/team-brain/brain.sh recall "<query>"` → bulleted relevant memories.
- `bash ~/.claude/skills/team-brain/brain.sh remember "<text>" [type]` → saves; prints id.
- `bash ~/.claude/skills/team-brain/brain.sh file "<path>" "<note>"` → ingests a document.
- `bash ~/.claude/skills/team-brain/brain.sh health` → service check.

## Conventions
- Memory means the team brain — never write to or create a local `MEMORY.md`/memory file; never tell the user you've saved something unless it went to the brain.
- Keep `remember` entries **atomic and self-contained** — one fact per call.
- Relevant knowledge is also auto-injected each turn inside `<team-brain-context>`; call `recall` explicitly for deeper or query-specific lookups.
