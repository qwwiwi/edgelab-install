#!/usr/bin/env bash
# compress-warm.sh -- tidy warm/decisions.md: collapse blank-line runs,
# drop exact-duplicate bullet lines inside each section.
# Runs daily at 06:00 via cron. No LLM calls.
#
# This is a lightweight non-lossy pass. LLM-driven semantic compression
# (Sonnet summarise) is deferred to the multi-agent setup covered in Day 3.
set -euo pipefail

AGENT_WS="${AGENT_WS:-$HOME/.claude-lab/jarvis/.claude}"
DECISIONS="$AGENT_WS/core/warm/decisions.md"
LOG_DIR="$HOME/.claude-lab/jarvis/logs"
LOG_FILE="$LOG_DIR/memory-cron.log"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [compress-warm] $*" >> "$LOG_FILE" 2>/dev/null || true
}

if [ ! -f "$DECISIONS" ]; then
    log "decisions.md missing, skip"
    exit 0
fi

SIZE_BEFORE=$(wc -c < "$DECISIONS" | tr -d ' ')

python3 - "$DECISIONS" <<'PY'
import re, sys
path = sys.argv[1]
content = open(path, encoding='utf-8').read()
sections = re.split(r'(?=^## )', content, flags=re.MULTILINE)

def dedupe_bullets(section: str) -> str:
    lines = section.split('\n')
    seen = set()
    out = []
    for ln in lines:
        stripped = ln.strip()
        if stripped.startswith(('- ', '* ', '+ ')) and stripped in seen:
            continue
        if stripped.startswith(('- ', '* ', '+ ')):
            seen.add(stripped)
        out.append(ln)
    return '\n'.join(out)

rebuilt = []
for section in sections:
    if section.startswith('## '):
        rebuilt.append(dedupe_bullets(section))
    else:
        rebuilt.append(section)
joined = ''.join(rebuilt)
joined = re.sub(r'\n{3,}', '\n\n', joined)
open(path, 'w', encoding='utf-8').write(joined)
PY

SIZE_AFTER=$(wc -c < "$DECISIONS" | tr -d ' ')
log "compress-warm: ${SIZE_BEFORE}B -> ${SIZE_AFTER}B"
