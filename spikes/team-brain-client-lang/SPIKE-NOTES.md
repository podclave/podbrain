# brain client: bash vs python vs elixir — spike findings

Three faithful ports of the team-brain client, same CLI + hook contract, proven
functionally identical (equivalence test + byte-identical distill output incl.
secret-scrub + feedback-loop strip + same-session exclusion).

Files: `brain.py` (stdlib only), `brain.exs` (zero deps — OTP 28
`:json`/`:httpc`/`:crypto`), `mockbrain.py` (test harness). The reference bash
client is the production one at `client/skills/team-brain/brain.sh`; the README
in this dir copies it in so the side-by-side comparison runs as documented.

## Measured on this Sprite (Opus box, OTP 28 JIT, py 3.13)

| metric | bash | python (stdlib) | elixir (no deps) |
|---|---|---|---|
| bare runtime boot | 7 ms | 162 ms | 508 ms |
| `recall` end-to-end (boot + 2 localhost HTTP) | 36 ms | 226 ms | 855 ms |
| `remember` (boot + 1 HTTP) | 26 ms | 228 ms | 871 ms |
| `hook-stop` return (blocks turn unless async) | 37 ms | 220 ms | 789 ms |
| Mix.install(jason) warm (rejected approach) | — | — | 697 ms (+3.2s cold) |
| lines / ~code / bytes | 177 / 127 / 11.5K | 405 / 344 / 16.3K | 390 / 332 / 16.2K |

## What the numbers mean for THIS workload
- The one **synchronous every-prompt** hook is `hook-recall` (UserPromptSubmit).
  Runtime adds ~0.04s (bash) / ~0.23s (py) / ~0.85s (exs) to every prompt *before*
  network RTT to the remote brain. exs's ~0.85s is felt; py's ~0.23s is borderline-
  invisible once real network latency is added; bash is free.
- `Stop` is `"async":true` in the managed settings, so its boot cost doesn't block
  the turn — but the **detached capture** does spin fresh runtimes: bash 2 procs,
  py 2 procs, **exs ~3 BEAM boots** (hook → setsid `_bgnow` → flock `_distill`).

## The decisive qualitative findings
1. **bash's "no deps" is half-myth**: it leans on `jq` (the dense, bug-prone part),
   `flock`, `setsid`, util-linux coreutils. Once jq is a dep, "needs python3" is not
   a step down — and python3 is already required by the *server* installer.
2. **python collapses the shell-outs into stdlib**: `jq`→`json`, `curl`→`urllib`,
   `flock`→`fcntl.flock`, `setsid`→`start_new_session=True`, `date %N`→`time_ns()`,
   `sed`→`re`. Dep surface SHRINKS to "python3 + claude + sprite-env". Distiller logic
   becomes testable + legible. Portable to macOS (bash uses Linux-only setsid/flock/%N).
3. **elixir fights its grain here**: BEAM stdlib has no fcntl/flock/setsid, so the
   no-dep port shells out to the SAME OS tools bash uses — then pays 0.5–0.9s boot
   *per invocation* on top, plus `:inets`/`:ssl` startup tax, plus ~3 boots per
   capture. Great language; wrong shape for short-lived CLI + per-prompt hooks.
   (It'd shine as a long-lived supervised daemon — a different architecture.)

## Bug found in the LIVE brain.sh (while porting)
`_bgsweep` skips the distiller's own `claude -p` transcripts via
`grep -q "memory distiller for a software team"` (line ~173) — but that phrase is
**no longer in the distiller prompt** (the anti-hijack rewrite changed INSTRUCTION to
"Your ONLY job is to extract durable team facts from a transcript"). So the guard is
**stale**: the sweep can re-ingest the distiller's own output. Both ports fix this by
deriving the guard from a single shared constant (`DISTILLER_MARKER` / `@marker`) that
is literally embedded in the instruction — two literals that must stay in sync became
one. brain.sh should get the same fix regardless of language choice.

## Recommendation
- Touching/extending the distiller, or want clean+portable opensource → **python**.
- Leaving it alone (proven, Sprite-only, distiller "done") → **keep bash**, but fix
  the stale sweep-guard.
- **Not elixir** for this client — empirically 3–4× python / 20–100× bash per call,
  and it shells out to the same OS tools anyway.
