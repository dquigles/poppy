#!/usr/bin/env bash
# Rebuilds Poppy Dev and (re)starts it beside the installed Poppy (DESIGN §12.1).
# Its appLog output goes to build/poppy-dev.log. Never touches the installed Poppy.
# Usage: ./scripts/dev.sh (works from any directory)
#        ./scripts/dev.sh --stop   only stop Poppy Dev
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Poppy Dev.app"
LOG="build/poppy-dev.log"

stop() {
    if pgrep -xq poppy-dev; then
        pkill -x poppy-dev || true
        for _ in {1..20}; do pgrep -xq poppy-dev || break; sleep 0.25; done
        echo "Stopped Poppy Dev"
    fi
}

case "${1:-}" in
    --stop) stop; exit 0 ;;
    "") ;;
    *) echo "usage: $0 [--stop]" >&2; exit 2 ;;
esac

./scripts/bundle.sh
stop
nohup "$APP/Contents/MacOS/poppy-dev" >"$LOG" 2>&1 &
pid=$!
sleep 1
if kill -0 "$pid" 2>/dev/null; then
    echo "Poppy Dev running (pid $pid); log: $LOG"
else
    echo "Poppy Dev exited at launch; log:" >&2
    cat "$LOG" >&2
    exit 1
fi
