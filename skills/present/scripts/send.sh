#!/usr/bin/env bash
set -euo pipefail
# Usage: send.sh <path/to/file.html>
# Sends the HTML file to the operator via Telegram sendDocument.
# chat_id resolves from PRESENT_CHAT_ID env var, else gateway config.

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <file>" >&2
    exit 2
fi

FILE="$1"
if [[ ! -f "$FILE" ]]; then
    echo "error: file not found: ${FILE}" >&2
    exit 1
fi

GATEWAY_DIR="${HOME}/claude-gateway"
TOKEN_FILE="${GATEWAY_DIR}/secrets/bot-token"
CONFIG_FILE="${GATEWAY_DIR}/config.json"

if [[ ! -r "$TOKEN_FILE" ]]; then
    echo "error: bot token not found at ${TOKEN_FILE}" >&2
    exit 1
fi

TG_ID="${PRESENT_CHAT_ID:-}"
if [[ -z "$TG_ID" && -f "$CONFIG_FILE" ]]; then
    TG_ID=$(jq -r '.allowlist_user_ids[0] // empty' "$CONFIG_FILE" 2>/dev/null || true)
fi
if [[ -z "$TG_ID" ]]; then
    echo "error: no chat id; set PRESENT_CHAT_ID or configure gateway allowlist" >&2
    exit 1
fi

TOKEN=$(cat "$TOKEN_FILE")
curl -fsSL --max-time 60 \
    -F "chat_id=${TG_ID}" \
    -F "document=@${FILE}" \
    "https://api.telegram.org/bot${TOKEN}/sendDocument" >/dev/null

echo "sent ${FILE##*/} to chat ${TG_ID}"
