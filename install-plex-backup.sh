#!/bin/bash
###############################################################################
# Plex Backup Installer
# https://github.com/biggux/plex-autoupdate
#
# Interactive installer for plex-backup.sh
###############################################################################

set -euo pipefail

INSTALL_DIR="/opt/plex-autoupdate"
CONFIG_FILE="/etc/plex-backup.conf"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

###############################################################################
# Functions
###############################################################################

print_header() {
    echo ""
    echo "=============================================="
    echo "  Plex Backup Installer"
    echo "=============================================="
    echo ""
}

prompt() {
    local var_name="$1"
    local prompt_text="$2"
    local default="${3:-}"
    local value

    if [[ -n "$default" ]]; then
        read -rp "$prompt_text [$default]: " value
        value="${value:-$default}"
    else
        read -rp "$prompt_text: " value
    fi

    eval "$var_name=\"$value\""
}

prompt_yn() {
    local var_name="$1"
    local prompt_text="$2"
    local default="${3:-yes}"
    local value

    read -rp "$prompt_text (yes/no) [$default]: " value
    value="${value:-$default}"
    value=$(echo "$value" | tr '[:upper:]' '[:lower:]')

    if [[ "$value" == "y" ]]; then
        value="yes"
    elif [[ "$value" == "n" ]]; then
        value="no"
    fi

    eval "$var_name=\"$value\""
}

validate_token() {
    local token="$1"
    local url="${2:-http://localhost:32400}"

    echo -n "  Validating token... "
    local response
    response=$(curl -sf -o /dev/null -w "%{http_code}" \
        -H "X-Plex-Token: $token" "$url/identity" 2>/dev/null) || response="000"

    if [[ "$response" == "200" ]]; then
        echo "OK"
        return 0
    else
        echo "FAILED (HTTP $response)"
        return 1
    fi
}

validate_path() {
    local path="$1"
    if [[ ! -d "$path" ]]; then
        echo -n "  Directory does not exist. Create it? "
        read -rp "(yes/no) [yes]: " create
        create="${create:-yes}"
        if [[ "$create" == "yes" || "$create" == "y" ]]; then
            mkdir -p "$path"
            echo "  Created: $path"
        else
            return 1
        fi
    fi
    # Test write access
    if touch "$path/.backup-test" 2>/dev/null; then
        rm -f "$path/.backup-test"
        return 0
    else
        echo "  ERROR: Cannot write to $path"
        return 1
    fi
}

select_schedule() {
    echo ""
    echo "How often should backups run?"
    echo ""
    echo "  1) Daily at 3:00 AM (default)"
    echo "  2) Twice daily (3:00 AM and 3:00 PM)"
    echo "  3) Every 6 hours"
    echo "  4) Weekly (Sunday 3:00 AM)"
    echo "  5) Custom cron expression"
    echo ""

    local choice
    read -rp "Select schedule [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1) CRON_EXPR="0 3 * * *" ; CRON_DESC="Daily at 3:00 AM" ;;
        2) CRON_EXPR="0 3,15 * * *" ; CRON_DESC="Twice daily (3:00 AM, 3:00 PM)" ;;
        3) CRON_EXPR="0 */6 * * *" ; CRON_DESC="Every 6 hours" ;;
        4) CRON_EXPR="0 3 * * 0" ; CRON_DESC="Weekly on Sunday at 3:00 AM" ;;
        5)
            read -rp "Enter cron expression: " CRON_EXPR
            CRON_DESC="Custom: $CRON_EXPR"
            ;;
        *) CRON_EXPR="0 3 * * *" ; CRON_DESC="Daily at 3:00 AM" ;;
    esac
}

###############################################################################
# Main
###############################################################################

# Must be root
if [[ $EUID -ne 0 ]]; then
    echo "This installer must be run as root (sudo)."
    exit 1
fi

print_header

# Check for existing config
EXISTING_TOKEN=""
EXISTING_URL="http://localhost:32400"
EXISTING_BACKUP_DIR=""
EXISTING_COMPONENTS="database preferences plugins"
EXISTING_DB_DIR="/var/lib/plexmediaserver/db-local"
EXISTING_RETENTION="7"
EXISTING_STOP="yes"
EXISTING_WAIT="yes"
EXISTING_WAIT_MIN="60"
EXISTING_COMPRESSION="gzip"
EXISTING_EMAIL="no"
EXISTING_EMAIL_TO=""

if [[ -f "$CONFIG_FILE" ]]; then
    echo "Existing configuration found at $CONFIG_FILE"
    echo "Current values will be shown as defaults."
    echo ""
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    EXISTING_TOKEN="$PLEX_TOKEN"
    EXISTING_URL="$PLEX_URL"
    EXISTING_BACKUP_DIR="$BACKUP_DIR"
    EXISTING_COMPONENTS="$BACKUP_COMPONENTS"
    EXISTING_DB_DIR="$PLEX_DB_DIR"
    EXISTING_RETENTION="$RETENTION_COUNT"
    EXISTING_STOP="$STOP_PLEX"
    EXISTING_WAIT="$WAIT_FOR_STREAMS"
    EXISTING_WAIT_MIN="$MAX_WAIT_MINUTES"
    EXISTING_COMPRESSION="$COMPRESSION"
    EXISTING_EMAIL="$EMAIL_ENABLED"
    EXISTING_EMAIL_TO="$EMAIL_TO"
fi

# --- Plex Token ---
echo "── Plex Token ──"
echo "  Find yours: https://support.plex.tv/articles/204059436"
echo ""
prompt PLEX_TOKEN "  Plex token" "$EXISTING_TOKEN"

# --- Plex URL ---
echo ""
prompt PLEX_URL "  Plex server URL" "$EXISTING_URL"

# Validate
if ! validate_token "$PLEX_TOKEN" "$PLEX_URL"; then
    echo "  WARNING: Could not validate token. Continuing anyway."
fi

# --- Backup Directory ---
echo ""
echo "── Backup Destination ──"
prompt BACKUP_DIR "  Backup directory" "$EXISTING_BACKUP_DIR"

if ! validate_path "$BACKUP_DIR"; then
    echo "  ERROR: Invalid backup path. Exiting."
    exit 1
fi

# --- Database Directory ---
echo ""
echo "── Plex Database Location ──"
prompt PLEX_DB_DIR "  Database directory" "$EXISTING_DB_DIR"

if [[ ! -d "$PLEX_DB_DIR" ]]; then
    echo "  WARNING: Directory does not exist: $PLEX_DB_DIR"
fi

# --- Components ---
echo ""
echo "── Backup Components ──"
echo "  Available: database, preferences, plugins"
prompt BACKUP_COMPONENTS "  Components (space-separated)" "$EXISTING_COMPONENTS"

# --- Retention ---
echo ""
echo "── Retention Policy ──"
prompt RETENTION_COUNT "  Number of backups to keep (0 = unlimited)" "$EXISTING_RETENTION"

# --- Compression ---
echo ""
prompt_yn COMPRESS_YN "  Compress backups with gzip?" "yes"
if [[ "$COMPRESS_YN" == "yes" ]]; then
    COMPRESSION="gzip"
else
    COMPRESSION="none"
fi

# --- Stop Plex ---
echo ""
echo "── Plex Shutdown Behavior ──"
prompt_yn STOP_PLEX "  Stop Plex before backup (recommended)?" "$EXISTING_STOP"

if [[ "$STOP_PLEX" == "yes" ]]; then
    prompt_yn WAIT_FOR_STREAMS "  Wait for active streams to finish?" "$EXISTING_WAIT"
    if [[ "$WAIT_FOR_STREAMS" == "yes" ]]; then
        prompt MAX_WAIT_MINUTES "  Max wait time in minutes" "$EXISTING_WAIT_MIN"
    else
        MAX_WAIT_MINUTES=0
    fi
else
    WAIT_FOR_STREAMS="no"
    MAX_WAIT_MINUTES=0
fi

# --- Email ---
echo ""
echo "── Email Notifications ──"
prompt_yn EMAIL_ENABLED "  Enable email notifications?" "$EXISTING_EMAIL"

if [[ "$EMAIL_ENABLED" == "yes" ]]; then
    prompt EMAIL_TO "  Recipient email" "$EXISTING_EMAIL_TO"
fi

# --- Schedule ---
select_schedule

# --- Summary ---
echo ""
echo "=============================================="
echo "  Configuration Summary"
echo "=============================================="
echo ""
echo "  Plex URL:       $PLEX_URL"
echo "  Token:          ${PLEX_TOKEN:0:8}..."
echo "  Backup dir:     $BACKUP_DIR"
echo "  DB dir:         $PLEX_DB_DIR"
echo "  Components:     $BACKUP_COMPONENTS"
echo "  Retention:      $RETENTION_COUNT backups"
echo "  Compression:    $COMPRESSION"
echo "  Stop Plex:      $STOP_PLEX"
echo "  Wait streams:   $WAIT_FOR_STREAMS"
echo "  Max wait:       ${MAX_WAIT_MINUTES}m"
echo "  Email:          $EMAIL_ENABLED"
echo "  Schedule:       $CRON_DESC"
echo ""

read -rp "Proceed with installation? (yes/no) [yes]: " confirm
confirm="${confirm:-yes}"

if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
    echo "Aborted."
    exit 0
fi

# --- Install ---
echo ""
echo "Installing..."

# Copy script
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/plex-backup.sh" "$INSTALL_DIR/plex-backup.sh"
chmod 755 "$INSTALL_DIR/plex-backup.sh"
echo "  Installed script to $INSTALL_DIR/plex-backup.sh"

# Write config
cat > "$CONFIG_FILE" << CONF
###############################################################################
# Plex Backup Configuration
# Generated by install-plex-backup.sh on $(date '+%Y-%m-%d %H:%M:%S')
###############################################################################

PLEX_TOKEN="$PLEX_TOKEN"
PLEX_URL="$PLEX_URL"
BACKUP_DIR="$BACKUP_DIR"
BACKUP_COMPONENTS="$BACKUP_COMPONENTS"
PLEX_DATA_DIR=""
PLEX_DB_DIR="$PLEX_DB_DIR"
RETENTION_COUNT=$RETENTION_COUNT
STOP_PLEX="$STOP_PLEX"
WAIT_FOR_STREAMS="$WAIT_FOR_STREAMS"
MAX_WAIT_MINUTES=$MAX_WAIT_MINUTES
CHECK_INTERVAL_SECONDS=120
COMPRESSION="$COMPRESSION"
EMAIL_ENABLED="$EMAIL_ENABLED"
EMAIL_TO="$EMAIL_TO"
EMAIL_FROM="plex-backup@$(hostname -f 2>/dev/null || hostname)"
EMAIL_SUBJECT_PREFIX="[Plex Backup]"
LOG_FILE="/var/log/plex-backup.log"
CONF

chmod 600 "$CONFIG_FILE"
echo "  Config written to $CONFIG_FILE"

# Set up cron (remove existing plex-backup entry first)
CRON_CMD="$CRON_EXPR $INSTALL_DIR/plex-backup.sh >> /var/log/plex-backup.log 2>&1"
(crontab -l 2>/dev/null | grep -v "plex-backup.sh"; echo "$CRON_CMD") | crontab -
echo "  Cron job installed: $CRON_DESC"

echo ""
echo "=============================================="
echo "  Installation Complete"
echo "=============================================="
echo ""
echo "  Script:    $INSTALL_DIR/plex-backup.sh"
echo "  Config:    $CONFIG_FILE"
echo "  Schedule:  $CRON_DESC"
echo "  Log:       /var/log/plex-backup.log"
echo ""
echo "  Run manually:  sudo $INSTALL_DIR/plex-backup.sh"
echo "  View logs:     tail -f /var/log/plex-backup.log"
echo ""
