#!/usr/bin/env bash
# Run a test gate. Same command for every phase, and afterwards the same
# command as a health check:
#
#   ./selftest.sh --phase 1
#   ./selftest.sh                 # everything that is switched on
#
# Exits 0 only if every check passed, so it works in cron and in CI unchanged.
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

COMPOSE="docker compose"
if ! docker compose version >/dev/null 2>&1; then
    COMPOSE="docker-compose"
fi

# Prefer the running watcher — it already has the config and the model mounted.
if $COMPOSE ps --status running --services 2>/dev/null | grep -qx watcher; then
    exec $COMPOSE exec -T watcher python selftest.py "$@"
fi

echo "watcher is not running; starting a throwaway container instead" >&2
exec $COMPOSE run --rm --no-deps -T watcher python selftest.py "$@"
