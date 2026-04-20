#!/usr/bin/env bash
set -euo pipefail
# Usage: delete.sh ID
# Remove a reminder cron line by its qr:ID=<nonce> tag.

if [[ $# -ne 1 ]]; then
    echo "usage: $0 ID" >&2
    exit 2
fi

ID="$1"
TAG="qr:ID=${ID}"

BEFORE=$(crontab -l 2>/dev/null | wc -l || echo 0)
crontab -l 2>/dev/null | grep -vF "$TAG" | crontab -
AFTER=$(crontab -l 2>/dev/null | wc -l || echo 0)

REMOVED=$((BEFORE - AFTER))
if [[ "$REMOVED" -gt 0 ]]; then
    echo "deleted reminder ${ID} (${REMOVED} cron line removed)"
else
    echo "no reminder found with id ${ID}" >&2
    exit 1
fi
