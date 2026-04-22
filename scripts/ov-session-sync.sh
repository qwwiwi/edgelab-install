#!/usr/bin/env bash
# ov-session-sync.sh -- push hot+warm memory into OpenViking for semantic recall.
# Runs daily at 06:30 via cron.
#
# OpenViking is an OPTIONAL external memory service. This installer does not
# provision one. The script is a no-op unless ALL of OPENVIKING_URL,
# OPENVIKING_KEY, OPENVIKING_ACCOUNT are set (usually in
# ~/.claude-lab/jarvis/.env, loaded below).
set -euo pipefail

AGENT_WS="${AGENT_WS:-$HOME/.claude-lab/jarvis/.claude}"
ENV_FILE="$HOME/.claude-lab/jarvis/.env"
RECENT="$AGENT_WS/core/hot/recent.md"
DECISIONS="$AGENT_WS/core/warm/decisions.md"
LOG_DIR="$HOME/.claude-lab/jarvis/logs"
LOG_FILE="$LOG_DIR/memory-cron.log"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [ov-session-sync] $*" >> "$LOG_FILE" 2>/dev/null || true
}

# Load env if present. We DO NOT `source` the file -- a sourced .env would let
# any command substitution or shell syntax execute under the cron user. Instead,
# we whitelist-parse three specific keys in pure bash as literal KEY=VALUE pairs.
parse_env_value() {
    # Strip one surrounding quote pair ("..." or '...'), leave inside as-is.
    local v="$1"
    if [ "${#v}" -ge 2 ]; then
        local first="${v:0:1}"
        local last="${v: -1}"
        if [ "$first" = "$last" ] && { [ "$first" = '"' ] || [ "$first" = "'" ]; }; then
            v="${v:1:${#v}-2}"
        fi
    fi
    printf '%s' "$v"
}

if [ -f "$ENV_FILE" ]; then
    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        # Skip blanks and comments.
        case "$raw_line" in
            ''|\#*|*[!\ \	]*) : ;;
        esac
        [ -z "${raw_line// /}" ] && continue
        trimmed="${raw_line#"${raw_line%%[![:space:]]*}"}"
        case "$trimmed" in
            ''|\#*) continue ;;
        esac
        # Key=Value split.
        key="${trimmed%%=*}"
        [ "$key" = "$trimmed" ] && continue
        value="${trimmed#*=}"
        # Trim trailing whitespace on key.
        key="${key%"${key##*[![:space:]]}"}"
        # Whitelist.
        case "$key" in
            OPENVIKING_URL|OPENVIKING_KEY|OPENVIKING_ACCOUNT) ;;
            *) continue ;;
        esac
        # Must be ALL_CAPS identifier.
        case "$key" in
            *[!A-Z0-9_]*|[!A-Z]*) continue ;;
        esac
        # Strip quote pair.
        value="$(parse_env_value "$value")"
        # Reject values containing backtick or unescaped $ -- those are the only
        # characters that can trigger shell expansion once exported to a child.
        case "$value" in
            *\`*|*\$*) continue ;;
        esac
        export "$key=$value"
    done < "$ENV_FILE"
fi

if [ -z "${OPENVIKING_URL:-}" ] || [ -z "${OPENVIKING_KEY:-}" ] || [ -z "${OPENVIKING_ACCOUNT:-}" ]; then
    log "OpenViking not configured -- skip (set OPENVIKING_URL/KEY/ACCOUNT in ${ENV_FILE} to enable)"
    exit 0
fi

sync_file() {
    local file="$1"
    local category="$2"
    [ -f "$file" ] || { log "skip ${category}: file missing"; return 0; }
    local body
    body=$(python3 -c 'import json,sys; p,c=sys.argv[1],sys.argv[2]; print(json.dumps({"category":c,"text":open(p,encoding="utf-8").read()}))' "$file" "$category")
    if curl -fsS -m 30 -X POST "${OPENVIKING_URL%/}/api/v1/capture" \
        -H "X-API-Key: ${OPENVIKING_KEY}" \
        -H "X-OpenViking-Account: ${OPENVIKING_ACCOUNT}" \
        -H "X-OpenViking-User: jarvis" \
        -H "Content-Type: application/json" \
        -d "$body" >/dev/null 2>&1; then
        log "synced ${category}"
    else
        log "failed to sync ${category}"
    fi
}

sync_file "$RECENT" "hot"
sync_file "$DECISIONS" "warm"
log "ov-session-sync complete"
