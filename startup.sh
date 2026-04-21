#!/bin/sh
set -eu

# ─── CONSTANTS ────────────────────────────────────────────────────────────────

TS_DIR=/teamspeak
TS_SAVE=${TS_DIR}/save

# ─── FUNCTIONS ────────────────────────────────────────────────────────────────

# Generates the minimal runscript for box64; idempotent.
create_minimal_runscript() {
    cat <<-'EOF' > "${TS_DIR}/ts3server_minimal_runscript.sh"
	#!/bin/sh
	set -e
	_self=$([ -x "$(command -v realpath)" ] && realpath "$0" || readlink -f "$0")
	cd "$(dirname "$_self")"

	if [ "$INIFILE" != 0 ]; then
	    if [ ! -e "/teamspeak/save/ts3server.ini" ]; then
	        echo "Generating default ts3server.ini..."
	        # Run the server briefly to create the ini file, then continue
	        /usr/bin/box64 ./ts3server inifile=save/ts3server.ini createinifile=1
	    fi
	    exec /usr/bin/box64 ./ts3server inifile=save/ts3server.ini
	else
	    exec /usr/bin/box64 ./ts3server "$@"
	fi
	EOF
    chmod +x "${TS_DIR}/ts3server_minimal_runscript.sh"
}

# Creates persistent directories in the volume mounted at /teamspeak/save.
create_persistent_dirs() {
    mkdir -p "${TS_SAVE}/files" "${TS_SAVE}/logs"
}

# Creates empty persistent files on first start.
create_persistent_files() {
    touch \
        "${TS_SAVE}/query_ip_whitelist.txt" \
        "${TS_SAVE}/query_ip_blacklist.txt" \
        "${TS_SAVE}/ts3server.sqlitedb"
}

# Creates symlinks between /teamspeak/save (volume) and /teamspeak.
# Uses -sf to make the operation idempotent for files;
# for directories uses conditional -s to avoid double nesting.
create_symlinks() {
    # Files: always idempotent with -sf
    for f in ts3server.sqlitedb query_ip_whitelist.txt query_ip_blacklist.txt ssh_host_rsa_key ts3server.ini; do
        ln -sf "${TS_SAVE}/${f}" "${TS_DIR}/${f}"
    done

    # Directories: idempotent with -sfn
    for d in logs files; do
        ln -sfn "${TS_SAVE}/${d}" "${TS_DIR}/${d}"
    done

    # Optional license
    rm -f "${TS_DIR}/licensekey.dat"
    [ -e "${TS_SAVE}/licensekey.dat" ] && \
        ln -sf "${TS_SAVE}/licensekey.dat" "${TS_DIR}/licensekey.dat" || true
}

# Fixes ownership of the entire installation only if necessary.
# Recursive chown can be very slow on volumes with many files, 
# but the base directory must ALWAYS be writable by the 'ts' user.
fix_ownership() {
    # 1. Always ensure the base installation directory is owned by ts (non-recursive, very fast)
    chown ts:ts "${TS_DIR}" /teamspeak_cached

    # 2. Check the persistent volume
    TARGET="${TS_SAVE}"
    [ -d "$TARGET" ] || TARGET="${TS_DIR}"

    CURRENT_UID=$(stat -c %u "$TARGET")
    CURRENT_GID=$(stat -c %g "$TARGET")
    DESIRED_UID=$(id -u ts)
    DESIRED_GID=$(id -g ts)

    if [ "$CURRENT_UID" != "$DESIRED_UID" ] || [ "$CURRENT_GID" != "$DESIRED_GID" ]; then
        echo "Ownership mismatch detected on $TARGET. Fixing permissions recursively..."
        chown -R ts:ts "${TS_DIR}" /teamspeak_cached
    else
        echo "Ownership on $TARGET is already correct ($DESIRED_UID:$DESIRED_GID). Skipping recursive chown."
    fi
}

# Cleans logs older than 7 days to prevent the volume from filling up.
cleanup_old_logs() {
    if [ -d "${TS_SAVE}/logs" ]; then
        echo "Cleaning up logs older than 7 days..."
        find "${TS_SAVE}/logs" -name "*.log" -type f -mtime +7 -delete || true
    fi
}

# ─── STARTUP LOGIC ────────────────────────────────────────────────────────────

# Validate PUID/PGID
case "$PUID" in ''|*[!0-9]*) echo "ERROR: PUID must be numeric"; exit 1 ;; esac
case "$PGID" in ''|*[!0-9]*) echo "ERROR: PGID must be numeric"; exit 1 ;; esac
if [ "$PUID" -eq 0 ] || [ "$PGID" -eq 0 ]; then
    echo "ERROR: Running as root (PUID/PGID=0) is not allowed."
    exit 1
fi

# Create ts user/group using PUID/PGID env vars.
# PUID/PGID are used instead of UID/GID to avoid clashing with the
# bash $UID read-only builtin (SC3028 in POSIX sh context).
if ! getent group "$PGID" >/dev/null 2>&1; then
    groupadd -g "$PGID" ts 2>/dev/null || true
fi
if ! id -u ts >/dev/null 2>&1; then
    useradd -u "$PUID" -g "$PGID" -d /teamspeak ts 2>/dev/null || \
        useradd -g "$PGID" -d /teamspeak ts
fi

# Update timezone if necessary
CURRENT_TIME_ZONE="$(cat /etc/timezone 2>/dev/null || echo '')"
if [ "$TIME_ZONE" != "$CURRENT_TIME_ZONE" ]; then
    TZ_FILE="/usr/share/zoneinfo/$TIME_ZONE"
    if [ ! -f "$TZ_FILE" ]; then
        echo "ERROR: Invalid timezone '$TIME_ZONE'"
        exit 1
    fi
    echo "Updating timezone to $TIME_ZONE"
    ln -fs "$TZ_FILE" /etc/localtime
    dpkg-reconfigure -f noninteractive tzdata
fi

# Write baked version to /teamspeak/version (used for informational purposes)
if [ -n "$TS_VERSION" ] && [ ! -e "/teamspeak/version" ]; then
    echo "$TS_VERSION" > /teamspeak/version
fi

# First-run: create persistent data structure if not present
if [ ! -e "${TS_SAVE}/ts3server.sqlitedb" ]; then
    create_persistent_dirs
    create_persistent_files
fi

# Always regenerate runscript (resilience against manual deletion/corruption)
create_minimal_runscript

# Flush pending writes before chown
sync

fix_ownership
create_symlinks
cleanup_old_logs

# Debug mode: block here so the container stays up for inspection
if [ "$DEBUG" != "0" ] || [ -e "${TS_SAVE}/debug" ]; then
    echo "DEBUG mode active - container is running but ts3server will not start."
    tail -f /dev/null
fi
