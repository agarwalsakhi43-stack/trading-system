#!/bin/bash
# Usage: ./notify.sh "Title" "Message"
TITLE="${1:-Trading Alert}"
MESSAGE="${2:-Signal triggered}"
osascript -e "display notification \"$MESSAGE\" with title \"$TITLE\" sound name \"Glass\""
