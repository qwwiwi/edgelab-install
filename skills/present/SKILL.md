---
name: present
description: Turn a block of markdown or data into a self-contained, pretty HTML presentation and send it back over Telegram as a file. Invoke when operator says "present this", "make a slide deck", "visualise", "make an HTML report".
---

# present

Given markdown, JSON, CSV or a plain prose brief, generate a clean HTML file
(self-contained, no external assets) and deliver it via Telegram `sendDocument`.

## When to use

- Operator says "present this", "slide this up", "make a slide deck".
- Operator asks for an HTML report from data.
- A subagent produced a long markdown doc and the operator wants to show it.

## How to call

```bash
# From the agent:
skills/present/scripts/build.sh <source.md> <output.html>
skills/present/scripts/send.sh <output.html>
```

## Design

- No external CSS / JS. Inline a small stylesheet (dark + light media query).
- No hardcoded chat_id, no hardcoded bot token -- both read at runtime from
  `${HOME}/claude-gateway/config.json` (allowlist_user_ids[0]) and
  `${HOME}/claude-gateway/secrets/bot-token`.
- Target chat is configurable via `PRESENT_CHAT_ID` env var (fallback to
  allowlist[0]).

## Delivery

```bash
TG_ID="${PRESENT_CHAT_ID:-$(jq -r '.allowlist_user_ids[0]' "${HOME}/claude-gateway/config.json")}"
TOKEN=$(cat "${HOME}/claude-gateway/secrets/bot-token")
curl -fsSL --max-time 60 \
  -F "chat_id=${TG_ID}" \
  -F "document=@${OUTPUT_HTML}" \
  "https://api.telegram.org/bot${TOKEN}/sendDocument"
```

## Differences from Silvana internal version

- `chat_id` is no longer hardcoded (was `164795011` in Silvana's copy).
- Bot token path is `${HOME}/claude-gateway/secrets/bot-token` (not
  `~/.claude-lab/silvana/secrets/...`).
- HTML template is operator-neutral (no "Silvana" / "Dark Lady" branding).
