#!/usr/bin/env bash
# memory-rotate.sh -- archive cold memory when it grows past threshold.
# Runs daily at 21:00 via cron. No LLM calls.
#
# When MEMORY.md > 5KB, move everything EXCEPT the first 20 lines
# (the current-interest header + top entries) into archive/YYYY-MM.md.
# Preserves strict append-only archive trail.
set -euo pipefail

AGENT_WS="${AGENT_WS:-$HOME/.claude-lab/jarvis/.claude}"
MEMORY="$AGENT_WS/core/MEMORY.md"
ARCHIVE_DIR="$AGENT_WS/core/archive"
LOG_DIR="$HOME/.claude-lab/jarvis/logs"
LOG_FILE="$LOG_DIR/memory-cron.log"
SIZE_LIMIT=5120  # 5KB
HEAD_LINES=20

mkdir -p "$LOG_DIR" "$ARCHIVE_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [memory-rotate] $*" >> "$LOG_FILE" 2>/dev/null || true
}

if [ ! -f "$MEMORY" ]; then
    log "MEMORY.md missing, skip"
    exit 0
fi

SIZE=$(wc -c < "$MEMORY" | tr -d ' ')
if [ "$SIZE" -le "$SIZE_LIMIT" ]; then
    log "MEMORY.md ok (${SIZE}B)"
    exit 0
fi

MONTH=$(date -u +%Y-%m)
ARCHIVE_FILE="$ARCHIVE_DIR/${MONTH}.md"

python3 - "$MEMORY" "$ARCHIVE_FILE" "$HEAD_LINES" <<'PY'
import sys
from pathlib import Path
memory = Path(sys.argv[1])
archive = Path(sys.argv[2])
head_lines = int(sys.argv[3])

lines = memory.read_text(encoding='utf-8').splitlines(keepends=True)
if len(lines) <= head_lines:
    sys.exit(0)

head = lines[:head_lines]
tail = lines[head_lines:]

# Append tail to month archive.
stamp = Path(archive).name
with archive.open('a', encoding='utf-8') as f:
    f.write(f"\n---\n(rotated from MEMORY.md into {stamp})\n")
    f.writelines(tail)

# Rewrite MEMORY.md with only the head.
memory.write_text(''.join(head).rstrip() + '\n', encoding='utf-8')
print(f"archived {len(tail)} line(s) to {archive.name}")
PY

log "memory-rotate complete (${SIZE}B -> archive/${MONTH}.md)"
