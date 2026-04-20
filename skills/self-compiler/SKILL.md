---
name: self-compiler
description: Rewrite or tune the agent CLAUDE.md + rules.md + USER.md based on accumulated LEARNINGS.md and operator feedback. Invoke when the operator says "recompile yourself", "update your rules", or when LEARNINGS.md has grown beyond ~30 entries.
---

# self-compiler

Read LEARNINGS.md + USER.md + rules.md, merge the highest-frequency lessons
into rules.md, and propose an updated CLAUDE.md. This is a **stub** -- full
classifier-backed self-tuning ships on Day-N.

## When to use

- `core/LEARNINGS.md` has 30+ entries.
- Operator asks to "update your rules" or "recompile yourself".
- The agent notices recurring corrections on the same topic.

## What to do (v2.2.0 stub)

1. Read `core/LEARNINGS.md` and group by first word / tag.
2. Promote any group that appears 3+ times into a one-line rule in `core/rules.md`.
3. Show the operator the diff and wait for confirmation before writing.
4. Never silently edit `CLAUDE.md` -- always propose, never apply.

## Not yet implemented (Day-N)

- Scored promotion pipeline (episodes.jsonl + learnings-engine).
- Automatic rule lint / regression testing.
- Cross-session pattern detection via Firebase.
