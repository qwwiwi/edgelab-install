#!/usr/bin/env bash
set -euo pipefail
# Usage: list.sh
# Print pending qr reminders with id, schedule, message.

crontab -l 2>/dev/null | awk '
/# qr:ID=/ {
    id = ""
    for (i = 1; i <= NF; i++) {
        if ($i ~ /^qr:ID=/) { sub(/^qr:ID=/, "", $i); id = $i }
    }
    # First 5 fields: minute hour day month dow
    sched = $1 " " $2 " " $3 " " $4 " " $5
    # Message is between `text=` and next `"`
    msg = ""
    line = $0
    if (match(line, /text="[^"]*"/)) {
        msg = substr(line, RSTART + 6, RLENGTH - 7)
    }
    printf "%s\t%s\t%s\n", id, sched, msg
}' || echo "(no reminders)"
