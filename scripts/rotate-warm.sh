#!/usr/bin/env bash
# rotate-warm.sh -- move oldest sections from warm/decisions.md into cold/MEMORY.md.
# Runs daily at 04:30 via cron. No LLM calls, deterministic.
#
# Heuristic: if decisions.md has > 14 "## " sections, the OLDEST section is
# appended to MEMORY.md with a "(rotated from decisions.md)" marker, and
# removed from decisions.md. Repeats until <= 14 sections.
set -euo pipefail

AGENT_WS="${AGENT_WS:-$HOME/.claude-lab/jarvis/.claude}"
DECISIONS="$AGENT_WS/core/warm/decisions.md"
MEMORY="$AGENT_WS/core/MEMORY.md"
LOG_DIR="$HOME/.claude-lab/jarvis/logs"
LOG_FILE="$LOG_DIR/memory-cron.log"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [rotate-warm] $*" >> "$LOG_FILE" 2>/dev/null || true
}

if [ ! -f "$DECISIONS" ]; then
    log "decisions.md missing, skip"
    exit 0
fi

# MEMORY.md might not exist on fresh install -- create it.
if [ ! -f "$MEMORY" ]; then
    printf '# MEMORY.md\n\nLong-term notes.\n' > "$MEMORY"
fi

SECTIONS=$(grep -c '^## ' "$DECISIONS" 2>/dev/null || true)
SECTIONS=${SECTIONS:-0}
if [ "$SECTIONS" -le 14 ]; then
    log "decisions.md has ${SECTIONS} sections, no rotation needed"
    exit 0
fi

python3 - "$DECISIONS" "$MEMORY" <<'PY'
import re, sys
dec_path, mem_path = sys.argv[1], sys.argv[2]
content = open(dec_path, encoding='utf-8').read()
sections = [(m.start(), m.group(0)) for m in re.finditer(r'^## .+$', content, re.MULTILINE)]
rotated = 0
while len(sections) > 14:
    oldest_start, oldest_header = sections[-1]
    oldest_text = content[oldest_start:]
    content = content[:oldest_start].rstrip() + "\n"
    with open(mem_path, 'a', encoding='utf-8') as f:
        f.write("\n---\n(rotated from decisions.md)\n" + oldest_text + "\n")
    rotated += 1
    sections = [(m.start(), m.group(0)) for m in re.finditer(r'^## .+$', content, re.MULTILINE)]
open(dec_path, 'w', encoding='utf-8').write(content)
print(f"rotated: {rotated} section(s) to MEMORY.md")
PY

log "rotate-warm complete"
