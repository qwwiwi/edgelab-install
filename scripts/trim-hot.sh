#!/usr/bin/env bash
# trim-hot.sh -- trim hot memory (recent.md + handoff.md) by size and age.
# Runs daily at 05:00 via cron. No LLM calls, deterministic.
#
# Behavior:
#   - recent.md > 12KB: keep last 50 "### " entries, shrink until < 12KB (min 10).
#   - handoff.md > 4KB: UTF-8-safe byte trim to 4KB, snap to last newline.
#   - handoff.md mtime > 6h: overwrite with "stale" placeholder.
set -euo pipefail

AGENT_WS="${AGENT_WS:-$HOME/.claude-lab/jarvis/.claude}"
RECENT="$AGENT_WS/core/hot/recent.md"
HANDOFF="$AGENT_WS/core/hot/handoff.md"
LOG_DIR="$HOME/.claude-lab/jarvis/logs"
LOG_FILE="$LOG_DIR/memory-cron.log"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [trim-hot] $*" >> "$LOG_FILE" 2>/dev/null || true
}

# -------- recent.md: size cap --------
RECENT_LIMIT=12288  # 12KB
if [ -f "$RECENT" ]; then
    SIZE=$(wc -c < "$RECENT" | tr -d ' ')
    if [ "$SIZE" -gt "$RECENT_LIMIT" ]; then
        cp "$RECENT" "${RECENT}.pre-trim"
        python3 - "$RECENT" "$RECENT_LIMIT" <<'PY'
import re, sys
path = sys.argv[1]
limit = int(sys.argv[2])
content = open(path, encoding='utf-8').read()
header_match = re.match(r'^#[^#].*\n', content)
header = header_match.group(0) if header_match else "# Hot memory -- rolling journal\n\n"
entries = list(re.finditer(r'^### ', content, re.MULTILINE))
total = len(entries)
if total > 50:
    keep_from = entries[-50].start()
    trimmed = header + "\n" + content[keep_from:]
    entries = list(re.finditer(r'^### ', trimmed, re.MULTILINE))
else:
    trimmed = content
while len(trimmed.encode('utf-8')) > limit and len(entries) > 10:
    # Drop the oldest entry and re-slice from the next-oldest. Entry offsets
    # must be recomputed against the CURRENT `trimmed`, otherwise the second
    # and later iterations cut at stale indices and corrupt the file.
    next_start = entries[1].start()
    trimmed = header + "\n" + trimmed[next_start:]
    entries = list(re.finditer(r'^### ', trimmed, re.MULTILINE))
open(path, 'w', encoding='utf-8').write(trimmed)
final = len(list(re.finditer(r'^### ', trimmed, re.MULTILINE)))
print(f"recent trimmed: {total} -> {final} entries, {len(trimmed.encode('utf-8'))}B")
PY
        log "recent.md trimmed from ${SIZE}B"
    else
        log "recent.md ok (${SIZE}B)"
    fi
fi

# -------- handoff.md: staleness + byte cap --------
HANDOFF_SIZE_LIMIT=4096
HANDOFF_STALE_HOURS=6

if [ -f "$HANDOFF" ]; then
    FILE_MOD=$(stat -c%Y "$HANDOFF" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    AGE_HOURS=$(( (NOW - FILE_MOD) / 3600 ))

    if [ "$AGE_HOURS" -ge "$HANDOFF_STALE_HOURS" ]; then
        cat > "$HANDOFF" <<STALE
# handoff.md -- last 10 entries (@include)

Previous session ended more than ${HANDOFF_STALE_HOURS}h ago. Context stale.
Start a fresh session: recall recent work from core/hot/recent.md if needed.
STALE
        log "handoff.md stale (${AGE_HOURS}h), cleared"
    else
        SIZE=$(wc -c < "$HANDOFF" | tr -d ' ')
        if [ "$SIZE" -gt "$HANDOFF_SIZE_LIMIT" ]; then
            TMPFILE=$(mktemp "${HANDOFF}.XXXXXX")
            python3 - "$HANDOFF" "$TMPFILE" "$HANDOFF_SIZE_LIMIT" <<'PY'
from pathlib import Path
import sys
handoff = Path(sys.argv[1])
tmpfile = Path(sys.argv[2])
max_bytes = int(sys.argv[3])
content = handoff.read_text(encoding='utf-8', errors='replace')
while len(content.encode('utf-8')) > max_bytes:
    content = content[:len(content)-100]
last_nl = content.rfind('\n')
if last_nl > 0:
    content = content[:last_nl]
tmpfile.write_text(content, encoding='utf-8')
PY
            mv "$TMPFILE" "$HANDOFF"
            log "handoff.md trimmed from ${SIZE}B to <=${HANDOFF_SIZE_LIMIT}B"
        fi
    fi
fi

log "trim-hot complete"
