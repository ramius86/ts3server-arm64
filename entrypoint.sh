#!/bin/sh
set -e

# Run as root: user/group creation, timezone setup, chown, symlinks
/teamspeak/startup.sh

# Start log forwarding in background.
# This loop handles log rotation by updating tail targets when new logs appear.
(
    while [ ! -d "/teamspeak/logs" ]; do sleep 1; done
    # Wait for the first log file to be created by TeamSpeak
    until ls /teamspeak/logs/ts3server_*.log >/dev/null 2>&1; do sleep 1; done
    echo "Log forwarder: starting dynamic log tailer..."

    current_files=""
    tail_pid=""
    while true; do
        new_files=$(ls /teamspeak/logs/ts3server_*.log 2>/dev/null | sort)
        if [ "$new_files" != "$current_files" ]; then
            if [ -n "$tail_pid" ] && kill -0 "$tail_pid" 2>/dev/null; then
                kill "$tail_pid" 2>/dev/null || true
                wait "$tail_pid" 2>/dev/null || true
            fi
            current_files="$new_files"
            # Use tail -n 0 to avoid printing existing logs again when tail restarts
            tail -n 0 -F -q $current_files &
            tail_pid=$!
        fi
        sleep 10
    done
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
