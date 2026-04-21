#!/bin/sh
set -e

# Run as root: user/group creation, timezone setup, chown, symlinks
/teamspeak/startup.sh

# Start log forwarding in background.
# Quiet, follow-mode tail on all log files.
(
    while [ ! -d "/teamspeak/logs" ]; do sleep 1; done
    # Wait for the first log file to be created by TeamSpeak
    until ls /teamspeak/logs/ts3server_*.log >/dev/null 2>&1; do sleep 1; done
    echo "Log forwarder: tailing logs to stdout..."
    exec tail -n 0 -F -q /teamspeak/logs/*.log
) &
TAIL_PID=$!

cleanup() {
    [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null || true
}
trap cleanup EXIT TERM INT

# Hand off to the TS3 server as ts user.
# Using exec here is standard practice to let tini manage the process.
if [ -e "/teamspeak/ts3server_minimal_runscript.sh" ]; then
    exec gosu ts /teamspeak/ts3server_minimal_runscript.sh
else
    echo "ERROR: startup.sh failed to create ts3server_minimal_runscript.sh."
    exit 1
fi
