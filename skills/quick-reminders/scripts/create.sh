#!/usr/bin/env bash
set -euo pipefail
# Usage: create.sh TIMESPEC MESSAGE
# TIMESPEC: anything `date -d` understands, e.g. "in 10 minutes", "tomorrow 9am", "2026-05-01 14:30".

if [[ $# -lt 2 ]]; then
    echo "usage: $0 TIMESPEC MESSAGE" >&2
    exit 2
fi

TIMESPEC="$1"
shift
MESSAGE="$*"

if ! TARGET_EPOCH=$(date -d "$TIMESPEC" +%s 2>/dev/null); then
    echo "error: cannot parse timespec '${TIMESPEC}'" >&2
    exit 1
fi

NOW=$(date +%s)
if [[ "$TARGET_EPOCH" -le "$NOW" ]]; then
    echo "error: timespec is in the past" >&2
    exit 1
fi

MIN=$(date -d "@${TARGET_EPOCH}" +%M)
HOUR=$(date -d "@${TARGET_EPOCH}" +%H)
DAY=$(date -d "@${TARGET_EPOCH}" +%d)
MON=$(date -d "@${TARGET_EPOCH}" +%m)

# One-shot: run at specific minute/hour/day/month, then remove its own cron line.
NONCE=$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')
GATEWAY_DIR="${HOME}/claude-gateway"
TOKEN_FILE="${GATEWAY_DIR}/secrets/bot-token"
CONFIG_FILE="${GATEWAY_DIR}/config.json"

if [[ ! -r "$TOKEN_FILE" ]]; then
    echo "error: bot token not found at ${TOKEN_FILE}" >&2
    exit 1
fi

TG_ID=$(jq -r '.allowlist_user_ids[0] // empty' "$CONFIG_FILE" 2>/dev/null || true)
if [[ -z "$TG_ID" ]]; then
    echo "error: no Telegram ID configured in ${CONFIG_FILE}" >&2
    exit 1
fi

# Escape message for cron line (no newlines, no unescaped quotes)
SAFE_MSG=$(printf '%s' "$MESSAGE" | tr '\n' ' ' | sed 's/"/\\"/g')

CRON_LINE="${MIN} ${HOUR} ${DAY} ${MON} * TOKEN=\$(cat ${TOKEN_FILE}) && curl -fsSL --max-time 30 -d \"chat_id=${TG_ID}\" -d \"text=${SAFE_MSG}\" \"https://api.telegram.org/bot\${TOKEN}/sendMessage\" >/dev/null 2>&1; (crontab -l 2>/dev/null | grep -vF 'qr:ID=${NONCE}') | crontab - # qr:ID=${NONCE}"

( crontab -l 2>/dev/null; echo "$CRON_LINE" ) | crontab -

echo "scheduled: id=${NONCE} at=$(date -d "@${TARGET_EPOCH}" '+%Y-%m-%d %H:%M')"
echo "message: ${MESSAGE}"
