---
name: team-brain
description: Shared team memory. Use to RECALL prior decisions/facts/docs before non-trivial work, REMEMBER durable learnings, and FILE documents (PRDs, decks, PDFs) into the shared brain. Trigger on "file this", "what do we know about", "remember that", or before starting work on a known project area.
---

# Team Brain

A central, shared memory for the whole team. Every teammate's Claude reads from and writes to the same brain, so knowledge compounds across people and projects. Interact via the helper `skills/team-brain/brain.sh` (a thin curl wrapper; config lives in `brain.env`).

## When to use
- **Before** non-trivial work: `brain.sh recall "<topic/question>"` to pull prior decisions, gotchas, conventions, and filed docs.
- **After** learning something durable (a decision, a fix, a config fact, a convention): `brain.sh remember "<concise fact>" [fact|decision|lesson]`.
- When the user says **"file this"** about a document: `brain.sh file "<path>" "<optional note>"`.

## Commands
- `bash skills/team-brain/brain.sh recall "<query>"` → bulleted relevant memories.
- `bash skills/team-brain/brain.sh remember "<text>" [type]` → saves a memory; prints its id.
- `bash skills/team-brain/brain.sh file "<path>" "<note>"` → ingests a document (PDF/docx/md…).
- `bash skills/team-brain/brain.sh health` → service check.

## Conventions
- Keep `remember` entries **atomic and self-contained** — one fact per call.
- Recall is also injected automatically each turn by the UserPromptSubmit hook; call `recall` explicitly when you need deeper or query-specific results.
- Prefer recall-before-acting on anything that touches a shared project, convention, or prior decision.
