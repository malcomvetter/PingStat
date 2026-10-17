#!/usr/bin/env bash
# Thin wrapper: two Menu Bar rows are usually com.example.PingStat + org.malcomvetter.PingStat (stale LS entries).
exec "$(cd "$(dirname "$0")" && pwd)/prune-launch-services-pingstat.sh" "$@"
