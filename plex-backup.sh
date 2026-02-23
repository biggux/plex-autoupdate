#!/bin/bash
###############################################################################
# Plex Backup Script
# https://github.com/biggux/plex-autoupdate
#
# Backs up Plex databases, preferences, and plugin data with stream-aware
# scheduling and configurable retention.
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK_FILE="/tmp/plex-backup.lock"
CONFIG_FILE="/etc/plex-backup.conf"

# Defaults (overridden by config)
PLEX_TOKEN=""
PLEX_URL="http://localhost:32400"
BACKUP_DIR=""
BACKUP_COMPONENTS="database preferences plugins"
PLEX_DATA_DIR=""
PLEX_DB_DIR="/var/lib/plexmediaserver/db-local"
RETENTION_COUNT=7
STOP_PLEX="yes"
WAIT_FOR_STREAMS="yes"
MAX_WAIT_MINUTES=60
CHECK_INTERVAL_SECONDS=120
COMPRESSION="gzip"
EMAIL_ENABLED="no"
EMAIL_TO=""
EMAIL_FROM="plex-backup@$(hostname -f 2>/dev/null || hostname)"
EMAIL_SUBJECT_PREFIX="[Plex Backup]"
LOG_FILE="/var/log/plex-backup.log"

###############################################################################
# Functions
###############################################################################

log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$timestamp] [$level] $msg" | tee -a "$LOG_FILE"
}

send_email() {
    local subject="$1"
    local body="$2"
    if [[ "$EMAIL_ENABLED" == "yes" && -n "$EMAIL_TO" ]]; then
        echo "$body" | mail -s "$EMAIL_SUBJECT_PREFIX $subject" -r "$EMAIL_FROM" "$EMAIL_TO" 2>/dev/null || true
    fi
}

cleanup() {
    rm -f "$LOCK_FILE"
}

get_active_sessions() {
    local count
    count=$(curl -sf -H "X-Plex-Token: $PLEX_TOKEN" \
        "$PLEX_URL/status/sessions" 2>/dev/null \
        | python3 -c "
import sys, xml.etree.ElementTree as ET
tree = ET.parse(sys.stdin)
print(tree.getroot().attrib.get('size', '0'))
" 2>/dev/null) || count="0"
    echo "$count"
}

wait_for_streams_to_finish() {
    if [[ "$WAIT_FOR_STREAMS" != "yes" ]]; then
        return 0
    fi

    local max_wait_seconds=$((MAX_WAIT_MINUTES * 60))
    local waited=0

    while true; do
        local sessions
        sessions=$(get_active_sessions)

        if [[ "$sessions" -eq 0 ]]; then
            log "INFO" "No active sessions. Proceeding."
            return 0
        fi

        if [[ "$max_wait_seconds" -gt 0 && "$waited" -ge "$max_wait_seconds" ]]; then
            log "WARN" "Timeout reached (${MAX_WAIT_MINUTES}m). Active sessions: $sessions. Skipping backup."
            send_email "Backup Skipped" "Backup skipped: $sessions active stream(s) still running after ${MAX_WAIT_MINUTES} minute timeout."
            return 1
        fi

        log "INFO" "Active sessions: $sessions. Waiting... (${waited}s / ${max_wait_seconds}s)"
        sleep "$CHECK_INTERVAL_SECONDS"
        waited=$((waited + CHECK_INTERVAL_SECONDS))
    done
}

stop_plex() {
    log "INFO" "Stopping Plex Media Server..."
    systemctl stop plexmediaserver 2>/dev/null || true
    sleep 3

    if systemctl is-active --quiet plexmediaserver 2>/dev/null; then
        log "ERROR" "Failed to stop Plex."
        return 1
    fi

    log "INFO" "Plex stopped."
    return 0
}

start_plex() {
    log "INFO" "Starting Plex Media Server..."
    systemctl start plexmediaserver 2>/dev/null || true
    sleep 5

    if systemctl is-active --quiet plexmediaserver 2>/dev/null; then
        log "INFO" "Plex is running."
    else
        log "ERROR" "Failed to start Plex!"
        send_email "Error: Plex Failed to Start" "Plex Media Server failed to start after backup. Manual intervention required."
    fi
}

detect_plex_data_dir() {
    if [[ -n "$PLEX_DATA_DIR" ]]; then
        return
    fi

    local default_dir="/var/lib/plexmediaserver/Library/Application Support/Plex Media Server"
    if [[ -d "$default_dir" ]]; then
        PLEX_DATA_DIR="$default_dir"
    else
        log "ERROR" "Could not detect Plex data directory. Set PLEX_DATA_DIR in config."
        exit 1
    fi
}

backup_database() {
    local dest="$1"
    local db_dir="$PLEX_DB_DIR"

    if [[ ! -d "$db_dir" ]]; then
        log "WARN" "Database directory not found: $db_dir. Skipping database backup."
        return
    fi

    log "INFO" "Backing up databases from $db_dir..."
    mkdir -p "$dest/database"
    cp -a "$db_dir"/* "$dest/database/" 2>/dev/null || true

    local count
    count=$(find "$dest/database" -type f | wc -l)
    local size
    size=$(du -sh "$dest/database" 2>/dev/null | cut -f1)
    log "INFO" "Database backup complete: $count files, $size"
}

backup_preferences() {
    local dest="$1"

    local prefs_file="$PLEX_DATA_DIR/Preferences.xml"
    if [[ ! -f "$prefs_file" ]]; then
        log "WARN" "Preferences.xml not found at $prefs_file. Skipping."
        return
    fi

    log "INFO" "Backing up Preferences.xml..."
    mkdir -p "$dest/preferences"
    cp -a "$prefs_file" "$dest/preferences/"
    log "INFO" "Preferences backup complete."
}

backup_plugins() {
    local dest="$1"

    local plugin_dir="$PLEX_DATA_DIR/Plug-in Support"
    if [[ ! -d "$plugin_dir" ]]; then
        log "WARN" "Plugin directory not found at $plugin_dir. Skipping."
        return
    fi

    log "INFO" "Backing up plugin data..."
    mkdir -p "$dest/plugins"
    cp -a "$plugin_dir"/* "$dest/plugins/" 2>/dev/null || true

    local size
    size=$(du -sh "$dest/plugins" 2>/dev/null | cut -f1)
    log "INFO" "Plugin backup complete: $size"
}

compress_backup() {
    local backup_path="$1"
    local archive_name="$2"

    if [[ "$COMPRESSION" == "gzip" ]]; then
        log "INFO" "Compressing backup..."
        tar -czf "${archive_name}.tar.gz" -C "$(dirname "$backup_path")" "$(basename "$backup_path")"
        rm -rf "$backup_path"
        local size
        size=$(du -sh "${archive_name}.tar.gz" 2>/dev/null | cut -f1)
        log "INFO" "Compressed to ${archive_name}.tar.gz ($size)"
    fi
}

enforce_retention() {
    if [[ "$RETENTION_COUNT" -le 0 ]]; then
        return
    fi

    log "INFO" "Enforcing retention policy: keeping last $RETENTION_COUNT backups..."

    local count
    if [[ "$COMPRESSION" == "gzip" ]]; then
        count=$(find "$BACKUP_DIR" -maxdepth 1 -name "plex-backup-*.tar.gz" | wc -l)
        if [[ "$count" -gt "$RETENTION_COUNT" ]]; then
            local to_delete=$((count - RETENTION_COUNT))
            find "$BACKUP_DIR" -maxdepth 1 -name "plex-backup-*.tar.gz" -printf '%T+ %p\n' \
                | sort | head -n "$to_delete" | awk '{print $2}' \
                | while read -r f; do
                    log "INFO" "Removing old backup: $(basename "$f")"
                    rm -f "$f"
                done
        fi
    else
        count=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name "plex-backup-*" | wc -l)
        if [[ "$count" -gt "$RETENTION_COUNT" ]]; then
            local to_delete=$((count - RETENTION_COUNT))
            find "$BACKUP_DIR" -maxdepth 1 -type d -name "plex-backup-*" -printf '%T+ %p\n' \
                | sort | head -n "$to_delete" | awk '{print $2}' \
                | while read -r f; do
                    log "INFO" "Removing old backup: $(basename "$f")"
                    rm -rf "$f"
                done
        fi
    fi
}

###############################################################################
# Main
###############################################################################

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [--config /path/to/config]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Load config
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    echo "Config file not found: $CONFIG_FILE"
    echo "Run install-plex-backup.sh or copy plex-backup.conf to /etc/plex-backup.conf"
    exit 1
fi

# Validate required settings
if [[ -z "$PLEX_TOKEN" ]]; then
    echo "PLEX_TOKEN is required. Set it in $CONFIG_FILE"
    exit 1
fi

if [[ -z "$BACKUP_DIR" ]]; then
    echo "BACKUP_DIR is required. Set it in $CONFIG_FILE"
    exit 1
fi

# Lock file to prevent overlapping runs
if [[ -f "$LOCK_FILE" ]]; then
    existing_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
        echo "Another backup is already running (PID: $existing_pid). Exiting."
        exit 0
    else
        rm -f "$LOCK_FILE"
    fi
fi

echo $$ > "$LOCK_FILE"
trap cleanup EXIT

# Start
log "INFO" "===== Plex Backup Started ====="
log "INFO" "Backup destination: $BACKUP_DIR"
log "INFO" "Components: $BACKUP_COMPONENTS"

# Detect Plex data directory
detect_plex_data_dir
log "INFO" "Plex data directory: $PLEX_DATA_DIR"
log "INFO" "Plex database directory: $PLEX_DB_DIR"

# Ensure backup directory exists
mkdir -p "$BACKUP_DIR"

# Create timestamped backup directory
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP_PATH="$BACKUP_DIR/plex-backup-$TIMESTAMP"
mkdir -p "$BACKUP_PATH"

# Determine if we need to stop Plex
PLEX_WAS_RUNNING=false
if systemctl is-active --quiet plexmediaserver 2>/dev/null; then
    PLEX_WAS_RUNNING=true
fi

PLEX_STOPPED=false

if [[ "$STOP_PLEX" == "yes" && "$PLEX_WAS_RUNNING" == true ]]; then
    # Wait for streams if configured
    if ! wait_for_streams_to_finish; then
        rm -rf "$BACKUP_PATH"
        log "INFO" "===== Plex Backup Skipped (active streams) ====="
        exit 0
    fi

    if stop_plex; then
        PLEX_STOPPED=true
    else
        log "ERROR" "Could not stop Plex. Proceeding with live backup."
    fi
fi

# Perform backups
BACKUP_OK=true

for component in $BACKUP_COMPONENTS; do
    case "$component" in
        database)
            backup_database "$BACKUP_PATH" || BACKUP_OK=false
            ;;
        preferences)
            backup_preferences "$BACKUP_PATH" || BACKUP_OK=false
            ;;
        plugins)
            backup_plugins "$BACKUP_PATH" || BACKUP_OK=false
            ;;
        *)
            log "WARN" "Unknown backup component: $component"
            ;;
    esac
done

# Restart Plex if we stopped it
if [[ "$PLEX_STOPPED" == true ]]; then
    start_plex
fi

# Compress if configured
if [[ "$COMPRESSION" == "gzip" ]]; then
    compress_backup "$BACKUP_PATH" "$BACKUP_DIR/plex-backup-$TIMESTAMP"
fi

# Enforce retention
enforce_retention

# Summary
if [[ "$COMPRESSION" == "gzip" ]]; then
    FINAL_SIZE=$(du -sh "$BACKUP_DIR/plex-backup-$TIMESTAMP.tar.gz" 2>/dev/null | cut -f1)
    FINAL_FILE="plex-backup-$TIMESTAMP.tar.gz"
else
    FINAL_SIZE=$(du -sh "$BACKUP_PATH" 2>/dev/null | cut -f1)
    FINAL_FILE="plex-backup-$TIMESTAMP/"
fi

if [[ "$BACKUP_OK" == true ]]; then
    log "INFO" "Backup complete: $FINAL_FILE ($FINAL_SIZE)"
    log "INFO" "===== Plex Backup Finished Successfully ====="
    send_email "Backup Complete" "Plex backup completed successfully.

File: $FINAL_FILE
Size: $FINAL_SIZE
Components: $BACKUP_COMPONENTS
Timestamp: $TIMESTAMP"
else
    log "ERROR" "Backup completed with errors. Check log for details."
    log "INFO" "===== Plex Backup Finished With Errors ====="
    send_email "Backup Completed With Errors" "Plex backup finished but encountered errors. Check $LOG_FILE for details."
fi
