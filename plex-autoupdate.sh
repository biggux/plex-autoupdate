#!/usr/bin/env bash
# =============================================================================
# Plex Media Server Auto-Updater
# =============================================================================
# Checks for new Plex versions (public or Plex Pass beta), waits for active
# streams to finish, then downloads, installs, and restarts Plex automatically.
#
# Usage:
#   ./plex-autoupdate.sh                  # Run with defaults from config
#   ./plex-autoupdate.sh --config /path   # Use a custom config file
#
# Recommended: run via cron, e.g. every 6 hours:
#   0 */6 * * * /opt/plex-autoupdate/plex-autoupdate.sh >> /var/log/plex-autoupdate.log 2>&1
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults (overridden by config file)
# ---------------------------------------------------------------------------
PLEX_TOKEN=""
PLEX_URL="http://localhost:32400"

# Update channel: "plexpass" for beta or "public" for stable releases
# Plex Pass subscribers can use "plexpass" to get early beta builds.
# Everyone else should use "public" for stable releases.
UPDATE_CHANNEL="public"

MAX_WAIT_MINUTES=360          # 6 hours default, configurable
CHECK_INTERVAL_SECONDS=120    # How often to re-check active sessions (2 min)

# Email notifications: set to "yes" to enable, "no" to disable
EMAIL_ENABLED="no"
EMAIL_TO=""
EMAIL_FROM="plex-updater@$(hostname -f 2>/dev/null || echo 'localhost')"
EMAIL_SUBJECT_PREFIX="[Plex Updater]"

LOG_FILE="/var/log/plex-autoupdate.log"
DOWNLOAD_DIR="/tmp/plex-update"
LOCK_FILE="/tmp/plex-autoupdate.lock"

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
CONFIG_FILE="/etc/plex-autoupdate.conf"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_FILE="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
else
    echo "WARNING: Config file $CONFIG_FILE not found. Using defaults."
fi

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [[ -z "$PLEX_TOKEN" ]]; then
    echo "ERROR: PLEX_TOKEN is not set. Configure it in $CONFIG_FILE"
    exit 1
fi

# Normalize UPDATE_CHANNEL
UPDATE_CHANNEL=$(echo "$UPDATE_CHANNEL" | tr '[:upper:]' '[:lower:]')
if [[ "$UPDATE_CHANNEL" != "plexpass" && "$UPDATE_CHANNEL" != "public" ]]; then
    echo "ERROR: UPDATE_CHANNEL must be 'plexpass' or 'public'. Got: $UPDATE_CHANNEL"
    exit 1
fi

# Normalize EMAIL_ENABLED
EMAIL_ENABLED=$(echo "$EMAIL_ENABLED" | tr '[:upper:]' '[:lower:]')

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE" >&2
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# ---------------------------------------------------------------------------
# Email notification
# ---------------------------------------------------------------------------
send_email() {
    local subject="$1"
    local body="$2"

    # Skip if email is disabled
    if [[ "$EMAIL_ENABLED" != "yes" ]]; then
        return 0
    fi

    if [[ -z "$EMAIL_TO" ]]; then
        log_warn "EMAIL_ENABLED=yes but EMAIL_TO is empty. Skipping email."
        return 0
    fi

    if command -v mail &>/dev/null; then
        echo -e "$body" | mail -s "${EMAIL_SUBJECT_PREFIX} ${subject}" -r "$EMAIL_FROM" "$EMAIL_TO"
        log_info "Email sent to $EMAIL_TO: $subject"
    elif command -v sendmail &>/dev/null; then
        {
            echo "From: $EMAIL_FROM"
            echo "To: $EMAIL_TO"
            echo "Subject: ${EMAIL_SUBJECT_PREFIX} ${subject}"
            echo ""
            echo -e "$body"
        } | sendmail -t
        log_info "Email sent to $EMAIL_TO: $subject"
    else
        log_warn "No mail command found. Install mailutils or postfix for email notifications."
    fi
}

# ---------------------------------------------------------------------------
# Lock file (prevent overlapping runs)
# ---------------------------------------------------------------------------
acquire_lock() {
    if [[ -f "$LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || true)
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            log_info "Another instance is already running (PID $lock_pid). Exiting."
            exit 0
        else
            log_warn "Stale lock file found. Removing."
            rm -f "$LOCK_FILE"
        fi
    fi
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE"' EXIT
}

# ---------------------------------------------------------------------------
# Plex API helpers
# ---------------------------------------------------------------------------
plex_api() {
    local endpoint="$1"
    curl -sS --max-time 30 \
        -H "X-Plex-Token: ${PLEX_TOKEN}" \
        -H "Accept: application/json" \
        "${PLEX_URL}${endpoint}" 2>/dev/null
}

get_installed_version() {
    # Try the Plex API first
    local version
    version=$(plex_api "/identity" | grep -oP '"version"\s*:\s*"\K[^"]+' 2>/dev/null || true)

    if [[ -z "$version" ]]; then
        # Fallback: check dpkg
        version=$(dpkg -s plexmediaserver 2>/dev/null | grep '^Version:' | awk '{print $2}' | cut -d'-' -f1)
    fi

    echo "$version"
}

get_latest_version() {
    local api_url channel_label

    if [[ "$UPDATE_CHANNEL" == "plexpass" ]]; then
        api_url="https://plex.tv/api/downloads/5.json?channel=plexpass"
        channel_label="Plex Pass (beta)"
    else
        api_url="https://plex.tv/api/downloads/5.json"
        channel_label="Public (stable)"
    fi

    log_info "Checking $channel_label channel for updates..."

    local response
    response=$(curl -sS --max-time 30 \
        "$api_url" \
        -H "X-Plex-Token: ${PLEX_TOKEN}" 2>/dev/null)

    if [[ -z "$response" ]]; then
        log_error "Failed to fetch latest version info from plex.tv"
        return 1
    fi

    # Extract version and download URL for Linux .deb (amd64)
    local version url
    version=$(echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
comp = data.get('computer', {}).get('Linux', {})
print(comp.get('version', ''))
" 2>/dev/null)

    url=$(echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
releases = data.get('computer', {}).get('Linux', {}).get('releases', [])
for r in releases:
    if 'debian' in r.get('distro', '').lower() or r.get('build', '').endswith('.deb'):
        url = r.get('url', '')
        if 'amd64' in url:
            print(url)
            break
" 2>/dev/null)

    if [[ -z "$version" ]]; then
        log_error "Could not parse latest version from plex.tv response"
        return 1
    fi

    echo "${version}|${url}"
}

get_active_sessions() {
    local response
    response=$(plex_api "/status/sessions")

    if [[ -z "$response" ]]; then
        # If we can't reach Plex, assume nobody is watching to be safe
        log_warn "Could not reach Plex API for session check. Assuming no active sessions."
        echo "0"
        return
    fi

    local count
    count=$(echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
mc = data.get('MediaContainer', {})
print(mc.get('size', 0))
" 2>/dev/null || echo "0")

    echo "$count"
}

get_session_details() {
    local response
    response=$(plex_api "/status/sessions")

    echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
mc = data.get('MediaContainer', {})
metadata = mc.get('Metadata', [])
for m in metadata:
    user = m.get('User', {}).get('title', 'Unknown')
    title = m.get('title', 'Unknown')
    gp_title = m.get('grandparentTitle', '')
    state = m.get('Player', {}).get('state', 'unknown')
    if gp_title:
        print(f'  - {user}: {gp_title} - {title} ({state})')
    else:
        print(f'  - {user}: {title} ({state})')
" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Version comparison
# ---------------------------------------------------------------------------
version_gt() {
    # Returns 0 (true) if $1 > $2 using version sorting
    [[ "$(printf '%s\n%s' "$1" "$2" | sort -V | tail -n1)" == "$1" ]] && [[ "$1" != "$2" ]]
}

# ---------------------------------------------------------------------------
# Update process
# ---------------------------------------------------------------------------
download_update() {
    local url="$1"
    local filename

    mkdir -p "$DOWNLOAD_DIR"
    filename=$(basename "$url" | cut -d'?' -f1)

    log_info "Downloading: $filename"
    if curl -L --max-time 300 -o "${DOWNLOAD_DIR}/${filename}" "$url" 2>/dev/null; then
        echo "${DOWNLOAD_DIR}/${filename}"
    else
        log_error "Download failed"
        return 1
    fi
}

wait_for_idle() {
    local max_seconds=$((MAX_WAIT_MINUTES * 60))
    local elapsed=0

    while (( elapsed < max_seconds )); do
        local sessions
        sessions=$(get_active_sessions)

        if [[ "$sessions" -eq 0 ]]; then
            log_info "No active sessions. Proceeding with update."
            return 0
        fi

        log_info "Active sessions: $sessions. Waiting... (${elapsed}s / ${max_seconds}s)"
        get_session_details
        sleep "$CHECK_INTERVAL_SECONDS"
        elapsed=$((elapsed + CHECK_INTERVAL_SECONDS))
    done

    log_warn "Timeout reached after ${MAX_WAIT_MINUTES} minutes. Active sessions still present."
    return 1
}

stop_plex() {
    log_info "Stopping Plex Media Server..."
    if systemctl is-active --quiet plexmediaserver; then
        systemctl stop plexmediaserver
        sleep 5
        if systemctl is-active --quiet plexmediaserver; then
            log_error "Failed to stop Plex"
            return 1
        fi
    fi
    log_info "Plex stopped."
}

install_update() {
    local deb_file="$1"
    log_info "Installing: $(basename "$deb_file")"
    if dpkg -i "$deb_file"; then
        log_info "Installation successful."
    else
        log_error "dpkg install failed. Attempting to fix dependencies..."
        apt-get install -f -y
    fi
}

start_plex() {
    log_info "Starting Plex Media Server..."
    systemctl start plexmediaserver
    sleep 10

    if systemctl is-active --quiet plexmediaserver; then
        local new_ver
        new_ver=$(get_installed_version)
        log_info "Plex is running. Version: $new_ver"
    else
        log_error "Plex failed to start after update!"
        return 1
    fi
}

cleanup() {
    rm -rf "$DOWNLOAD_DIR"
}

# =============================================================================
# Main
# =============================================================================
main() {
    acquire_lock

    local channel_display
    if [[ "$UPDATE_CHANNEL" == "plexpass" ]]; then
        channel_display="Plex Pass (beta)"
    else
        channel_display="Public (stable)"
    fi

    log_info "===== Plex Auto-Update Check Started [Channel: $channel_display] ====="

    # 1. Get current and latest versions
    local installed_version
    installed_version=$(get_installed_version)
    if [[ -z "$installed_version" ]]; then
        log_error "Could not determine installed Plex version. Is Plex installed?"
        send_email "Error: Cannot determine version" \
            "Could not determine the currently installed Plex version. Is Plex installed and running?"
        exit 1
    fi
    log_info "Installed version: $installed_version"

    local latest_info latest_version download_url
    latest_info=$(get_latest_version) || exit 1
    latest_version=$(echo "$latest_info" | cut -d'|' -f1)
    download_url=$(echo "$latest_info" | cut -d'|' -f2-)
    log_info "Latest $channel_display version: $latest_version"

    # 2. Compare versions
    # Strip any build metadata for comparison (e.g., 1.40.1.8227-abcdef123)
    local installed_base latest_base
    installed_base=$(echo "$installed_version" | grep -oP '^\d+\.\d+\.\d+\.\d+' || echo "$installed_version")
    latest_base=$(echo "$latest_version" | grep -oP '^\d+\.\d+\.\d+\.\d+' || echo "$latest_version")

    if ! version_gt "$latest_base" "$installed_base"; then
        log_info "Already up to date. Nothing to do."
        exit 0
    fi

    log_info "New version available: $latest_version (current: $installed_version)"
    send_email "Update available: $latest_version" \
        "A new $channel_display version is available.\n\nCurrent: $installed_version\nNew: $latest_version\n\nStarting update process..."

    # 3. Download the update first (while people may still be watching)
    if [[ -z "$download_url" ]]; then
        log_error "No .deb download URL found for amd64. Check the Plex API response."
        send_email "Error: No download URL" \
            "Found new version $latest_version but could not find an amd64 .deb download URL."
        exit 1
    fi

    local deb_file
    deb_file=$(download_update "$download_url") || {
        send_email "Error: Download failed" \
            "Failed to download Plex $latest_version from:\n$download_url"
        exit 1
    }
    log_info "Downloaded to: $deb_file"

    # 4. Wait for active streams to finish
    if ! wait_for_idle; then
        send_email "Update postponed: active sessions" \
            "Plex $latest_version is downloaded but users are still streaming after ${MAX_WAIT_MINUTES} minutes.\n\nThe update will be retried on the next run."
        cleanup
        exit 0
    fi

    # 5. Stop, install, start
    stop_plex || {
        send_email "Error: Could not stop Plex" \
            "Failed to stop Plex Media Server. Update aborted."
        exit 1
    }

    install_update "$deb_file" || {
        log_error "Install failed. Attempting to restart Plex with old version..."
        start_plex
        send_email "Error: Install failed" \
            "Failed to install Plex $latest_version. Plex has been restarted with the previous version."
        cleanup
        exit 1
    }

    start_plex || {
        send_email "CRITICAL: Plex won't start" \
            "Plex was updated to $latest_version but failed to start!\n\nManual intervention required."
        cleanup
        exit 1
    }

    # 6. Done
    cleanup
    local final_version
    final_version=$(get_installed_version)
    log_info "===== Update complete: $installed_version -> $final_version ====="
    send_email "Updated successfully to $final_version" \
        "Plex Media Server has been updated.\n\nPrevious: $installed_version\nNew: $final_version\nChannel: $channel_display\n\nServer is running normally."
}

main "$@"
