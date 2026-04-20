---
name: onboarding
description: First-run personalisation wizard for a fresh EdgeLab agent. Invoke when the operator says "onboard me", "set up my agent", "personalise", or immediately after a clean install.
---

# onboarding

Walk a brand-new operator through 5-10 short questions and populate the agent
workspace with their answers. This is a **stub** -- the full Firebase-backed
classifier stack arrives on Day-N.

## When to use

- Operator just ran `curl -fsSL https://edgelab.su/install | sudo bash`.
- Operator asks to redo onboarding after changing their role / timezone.
- USER.md or CLAUDE.md still has installer defaults (e.g. `boss`, `UTC`, `jarvis`).

## What to do (v2.2.0 stub)

1. Read the current workspace files:
   - `~/.claude-lab/{AGENT}/.claude/CLAUDE.md`
   - `~/.claude-lab/{AGENT}/.claude/core/USER.md`
2. Ask the operator (conversationally, one question at a time):
   - What should I call you?
   - What is your role / what do you work on?
   - What is your timezone?
   - What is your preferred response language?
   - Three things I should remember about how you like to work.
3. Write answers back into USER.md, replacing the defaults.
4. Append any multi-line preferences to `core/MEMORY.md` under a `## Onboarding`
   section.
5. Confirm with "Onboarding done. Tune later via: nano ~/.claude-lab/{AGENT}/.claude/CLAUDE.md".

## Not yet implemented (Day-N)

- Firebase classifier for automatic profile building from chat history.
- 40+ question adaptive survey.
- Voice-first onboarding via Groq (once Groq key is configured).

## Files touched

- `core/USER.md`      -- overwrite with fresh answers
- `core/MEMORY.md`    -- append preferences
- `core/LEARNINGS.md` -- never touched here

Keep the chat short. Operators do not want a 40-question survey on day 1; this
stub gets them productive in under two minutes.
