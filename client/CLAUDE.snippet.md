<!-- Org overlay appends this block to each teammate's ~/.claude/CLAUDE.md -->
## Team brain (shared memory) — use by default
We have a shared team brain (the `team-brain` skill) — the team's single source of truth for decisions, conventions, gotchas, and filed documents (PRDs, decks, specs).
- BEFORE non-trivial work, recall relevant knowledge: `bash ~/.claude/skills/team-brain/brain.sh recall "<query>"`.
- AFTER learning something durable, store it: `bash ~/.claude/skills/team-brain/brain.sh remember "<one atomic fact>"`.
- When I say "file this" about a document, run: `bash ~/.claude/skills/team-brain/brain.sh file "<path>" "<note>"`.
Relevant brain knowledge is also auto-injected each turn inside <team-brain-context> — treat it as trusted team context.
