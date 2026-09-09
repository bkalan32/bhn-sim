#!/usr/bin/env bash
# The scribe. Every game day (and every real bridge) has one; today it is also you.
#   ./gameday/note.sh "overview shows egift red, settlement row blank?"
# appends a UTC-timestamped line to gameday/timeline-1.md. Write what you SEE and what you
# DO, not what you think — the retro reads this as if joining 20 minutes in.
set -u
F="$(dirname "$0")/timeline-${GAMEDAY_RUN:-1}.md"
[[ $# -gt 0 ]] || { echo "usage: $0 \"what you see / what you did\""; exit 2; }
printf -- '- `%s` %s\n' "$(date -u +%H:%M:%SZ)" "$*" >> "$F"
tail -1 "$F"
