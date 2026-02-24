#!/bin/bash
###############################################################################
# Plex Tools Installer
# https://github.com/biggux/plex-autoupdate
#
# Interactive installer for:
#   - plex-autoupdate.sh  (auto-updater)
#   - plex-backup.sh      (automated backups)
###############################################################################

set -eo pipefail
EMAIL_TO="${EMAIL_TO:-}"

INSTALL_DIR="/opt/plex-autoupdate"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Config files
UPDATER_CONFIG="/etc/plex-autoupdate.conf"
BACKUP_CONFIG="/etc/plex-backup.conf"

###############################################################################
# Shared Functions
###############################################################################

print_banner() {
    echo ""
    echo "=============================================="
    echo "  🎬 Plex Tools Installer"
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

    case "$value" in
        y) value="yes" ;;
        n) value="no" ;;
    esac

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
        echo "OK ✅"
        return 0
    else
        echo "FAILED (HTTP $response) ❌"
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
    if touch "$path/.install-test" 2>/dev/null; then
        rm -f "$path/.install-test"
        return 0
    else
        echo "  ERROR: Cannot write to $path"
        return 1
    fi
}

check_dependencies() {
    echo "Checking dependencies..."
    for cmd in curl python3 dpkg systemctl; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "  ❌ '$cmd' is required but not found."
            exit 1
        fi
        echo "  ✅ $cmd"
    done

    if ! command -v crontab &>/dev/null; then
        echo "  ⚠️  cron not installed. Installing..."
        apt-get update -qq && apt-get install -y -qq cron
        systemctl enable cron
        systemctl start cron
        echo "  ✅ cron installed and started"
    else
        echo "  ✅ cron"
    fi
    echo ""
}

prompt_plex_token() {
    local existing="${1:-}"
    echo "── 🔑 Plex Token ──"
    echo "  Find yours: https://support.plex.tv/articles/204059436"
    echo ""
    prompt PLEX_TOKEN "  Plex token" "$existing"

    echo ""
    prompt PLEX_URL "  Plex server URL" "${2:-http://localhost:32400}"

    if ! validate_token "$PLEX_TOKEN" "$PLEX_URL"; then
        echo "  ⚠️  Could not validate token. Continuing anyway."
    fi
    echo ""
}

prompt_email() {
    local existing_enabled="${1:-no}"
    local existing_to="${2:-}"

    echo "── 📧 Email Notifications ──"
    prompt_yn EMAIL_ENABLED "  Enable email notifications?" "$existing_enabled"

    if [[ "$EMAIL_ENABLED" == "yes" ]]; then
        prompt EMAIL_TO "  Recipient email" "$existing_to"
        if [[ -z "$EMAIL_TO" ]]; then
            echo "  ⚠️  No email provided. Disabling."
            EMAIL_ENABLED="no"
        fi

        if ! command -v mail &>/dev/null && ! command -v sendmail &>/dev/null; then
            echo "  ⚠️  No mail command found. Install: apt install mailutils"
        fi
    fi
    echo ""
}

select_schedule() {
    local default_hour="${1:-3}"
    local tool_name="$2"

    echo "── 📅 Schedule ──"
    echo "  How often should $tool_name run?"
    echo ""
    echo "  1) Daily at ${default_hour}:00 AM (default)"
    echo "  2) Twice daily"
    echo "  3) Every 6 hours"
    echo "  4) Weekly (Sunday ${default_hour}:00 AM)"
    echo "  5) Custom cron expression"
    echo ""

    local choice
    read -rp "  Select schedule [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        2) CRON_EXPR="0 ${default_hour},$((default_hour+12)) * * *"
           CRON_DESC="Twice daily" ;;
        3) CRON_EXPR="0 */${default_hour} * * *"
           CRON_DESC="Every 6 hours" ;;
        4) CRON_EXPR="0 ${default_hour} * * 0"
           CRON_DESC="Weekly (Sunday ${default_hour}:00 AM)" ;;
        5) read -rp "  Enter cron expression: " CRON_EXPR
           CRON_DESC="Custom: $CRON_EXPR" ;;
        *) CRON_EXPR="0 ${default_hour} * * *"
           CRON_DESC="Daily at ${default_hour}:00 AM" ;;
    esac
    echo "  Selected: $CRON_DESC"
    echo ""
}

install_cron() {
    local script_name="$1"
    local log_file="$2"
    local cron_expr="$3"

    local cron_cmd="$cron_expr $INSTALL_DIR/$script_name >> $log_file 2>&1"
    (crontab -l 2>/dev/null | grep -v "$script_name"; echo "$cron_cmd") | crontab -
}

###############################################################################
# Auto-Updater Setup
###############################################################################

setup_updater() {
    echo ""
    echo "=============================================="
    echo "  🔄 Auto-Updater Setup"
    echo "=============================================="
    echo ""

    # Load existing config
    local EX_TOKEN="" EX_URL="http://localhost:32400" EX_CHANNEL="public"
    local EX_MAX_WAIT="360" EX_EMAIL="no" EX_EMAIL_TO=""

    if [[ -f "$UPDATER_CONFIG" ]]; then
        echo "  Existing config found. Current values shown as defaults."
        echo ""
        source "$UPDATER_CONFIG"
        EX_TOKEN="${PLEX_TOKEN:-}"
        EX_URL="${PLEX_URL:-http://localhost:32400}"
        EX_CHANNEL="${UPDATE_CHANNEL:-public}"
        EX_MAX_WAIT="${MAX_WAIT_MINUTES:-360}"
        EX_EMAIL="${EMAIL_ENABLED:-no}"
        EX_EMAIL_TO="${EMAIL_TO:-}"
    fi

    # Token (shared — may already be set)
    if [[ -z "${PLEX_TOKEN:-}" ]]; then
        prompt_plex_token "$EX_TOKEN" "$EX_URL"
    else
        echo "  Using Plex token from previous step."
        echo ""
    fi

    # Channel
    echo "── 📡 Update Channel ──"
    echo "  1) public    — Stable releases (recommended)"
    echo "  2) plexpass  — Beta builds (requires Plex Pass)"
    echo ""
    local ch_default="1"
    [[ "$EX_CHANNEL" == "plexpass" ]] && ch_default="2"
    local ch_choice
    read -rp "  Select channel [${ch_default}]: " ch_choice
    ch_choice="${ch_choice:-$ch_default}"
    case "$ch_choice" in
        2|plexpass) UPDATE_CHANNEL="plexpass" ;;
        *)          UPDATE_CHANNEL="public" ;;
    esac
    echo "  Selected: $UPDATE_CHANNEL"
    echo ""

    # Wait timeout
    echo "── ⏱️  Wait Timeout ──"
    prompt MAX_WAIT_MINUTES "  Max wait for streams (minutes)" "$EX_MAX_WAIT"
    if ! [[ "$MAX_WAIT_MINUTES" =~ ^[0-9]+$ ]]; then
        echo "  Invalid number. Using default: 360"
        MAX_WAIT_MINUTES=360
    fi
    echo ""

    # Email
    prompt_email "$EX_EMAIL" "$EX_EMAIL_TO"

    # Schedule
    select_schedule 2 "the auto-updater"
    UPDATER_CRON_EXPR="$CRON_EXPR"
    UPDATER_CRON_DESC="$CRON_DESC"

    # --- Summary ---
    echo "  ── Auto-Updater Summary ──"
    echo "  Plex URL:     $PLEX_URL"
    echo "  Token:        ${PLEX_TOKEN:0:8}..."
    echo "  Channel:      $UPDATE_CHANNEL"
    echo "  Max wait:     ${MAX_WAIT_MINUTES}m"
    echo "  Email:        $EMAIL_ENABLED${EMAIL_TO:+ ($EMAIL_TO)}"
    echo "  Schedule:     $UPDATER_CRON_DESC"
    echo ""

    # Save for shared use
    SHARED_TOKEN="$PLEX_TOKEN"
    SHARED_URL="$PLEX_URL"
    SHARED_EMAIL_ENABLED="$EMAIL_ENABLED"
    SHARED_EMAIL_TO="${EMAIL_TO:-}"
}

write_updater_config() {
    cat > "$UPDATER_CONFIG" << CONF
###############################################################################
# Plex Auto-Updater Configuration
# Generated by installer on $(date '+%Y-%m-%d %H:%M:%S')
###############################################################################

PLEX_TOKEN="$PLEX_TOKEN"
PLEX_URL="$PLEX_URL"

# Update channel: "plexpass" (beta) or "public" (stable)
UPDATE_CHANNEL="$UPDATE_CHANNEL"

# Max wait time for active streams (minutes)
MAX_WAIT_MINUTES=$MAX_WAIT_MINUTES

# Session check interval (seconds)
CHECK_INTERVAL_SECONDS=120

# Email notifications
EMAIL_ENABLED="$EMAIL_ENABLED"
EMAIL_TO="${EMAIL_TO:-}"
EMAIL_FROM="plex-updater@$(hostname -f 2>/dev/null || hostname)"
EMAIL_SUBJECT_PREFIX="[Plex Updater]"

# Paths
LOG_FILE="/var/log/plex-autoupdate.log"
DOWNLOAD_DIR="/tmp/plex-update"
CONF
    chmod 600 "$UPDATER_CONFIG"
}

install_updater() {
    echo "  Installing auto-updater..."
    cp "$SCRIPT_DIR/plex-autoupdate.sh" "$INSTALL_DIR/plex-autoupdate.sh"
    chmod 755 "$INSTALL_DIR/plex-autoupdate.sh"
    echo "    ✅ Script → $INSTALL_DIR/plex-autoupdate.sh"

    write_updater_config
    echo "    ✅ Config → $UPDATER_CONFIG"

    touch /var/log/plex-autoupdate.log
    chmod 644 /var/log/plex-autoupdate.log

    install_cron "plex-autoupdate.sh" "/var/log/plex-autoupdate.log" "$UPDATER_CRON_EXPR"
    echo "    ✅ Cron   → $UPDATER_CRON_DESC"
}

###############################################################################
# Backup Setup
###############################################################################

setup_backup() {
    echo ""
    echo "=============================================="
    echo "  💾 Backup Setup"
    echo "=============================================="
    echo ""

    # Load existing config
    local EX_TOKEN="${SHARED_TOKEN:-}" EX_URL="${SHARED_URL:-http://localhost:32400}"
    local EX_BACKUP_DIR="" EX_COMPONENTS="database preferences plugins"
    local EX_DB_DIR="/var/lib/plexmediaserver/db-local"
    local EX_RETENTION="7" EX_STOP="yes" EX_WAIT="yes" EX_WAIT_MIN="60"
    local EX_COMPRESSION="gzip"
    local EX_EMAIL="${SHARED_EMAIL_ENABLED:-no}" EX_EMAIL_TO="${SHARED_EMAIL_TO:-}"

    if [[ -f "$BACKUP_CONFIG" ]]; then
        echo "  Existing config found. Current values shown as defaults."
        echo ""
        source "$BACKUP_CONFIG"
        EX_TOKEN="${PLEX_TOKEN:-$EX_TOKEN}"
        EX_URL="${PLEX_URL:-$EX_URL}"
        EX_BACKUP_DIR="${BACKUP_DIR:-}"
        EX_COMPONENTS="${BACKUP_COMPONENTS:-database preferences plugins}"
        EX_DB_DIR="${PLEX_DB_DIR:-/var/lib/plexmediaserver/db-local}"
        EX_RETENTION="${RETENTION_COUNT:-7}"
        EX_STOP="${STOP_PLEX:-yes}"
        EX_WAIT="${WAIT_FOR_STREAMS:-yes}"
        EX_WAIT_MIN="${MAX_WAIT_MINUTES:-60}"
        EX_COMPRESSION="${COMPRESSION:-gzip}"
        EX_EMAIL="${EMAIL_ENABLED:-$EX_EMAIL}"
        EX_EMAIL_TO="${EMAIL_TO:-$EX_EMAIL_TO}"
    fi

    # Token (shared — may already be set)
    if [[ -z "${SHARED_TOKEN:-}" ]]; then
        prompt_plex_token "$EX_TOKEN" "$EX_URL"
        SHARED_TOKEN="$PLEX_TOKEN"
        SHARED_URL="$PLEX_URL"
    else
        PLEX_TOKEN="$SHARED_TOKEN"
        PLEX_URL="$SHARED_URL"
        echo "  Using Plex token from previous step."
        echo ""
    fi

    # Backup directory
    echo "── 📂 Backup Destination ──"
    prompt BACKUP_DIR "  Backup directory" "$EX_BACKUP_DIR"
    if ! validate_path "$BACKUP_DIR"; then
        echo "  ERROR: Invalid backup path. Exiting."
        exit 1
    fi
    echo ""

    # Database directory
    echo "── 🗄️  Database Location ──"
    prompt PLEX_DB_DIR "  Database directory" "$EX_DB_DIR"
    if [[ ! -d "$PLEX_DB_DIR" ]]; then
        echo "  ⚠️  Directory does not exist: $PLEX_DB_DIR"
    fi
    echo ""

    # Components
    echo "── 🧩 Backup Components ──"
    echo "  Available: database, preferences, plugins"
    prompt BACKUP_COMPONENTS "  Components (space-separated)" "$EX_COMPONENTS"
    echo ""

    # Retention
    echo "── 🗑️  Retention Policy ──"
    prompt RETENTION_COUNT "  Backups to keep (0 = unlimited)" "$EX_RETENTION"
    echo ""

    # Compression
    prompt_yn COMPRESS_YN "  📦 Compress backups with gzip?" "yes"
    [[ "$COMPRESS_YN" == "yes" ]] && COMPRESSION="gzip" || COMPRESSION="none"
    echo ""

    # Stop Plex
    echo "── 🛡️  Plex Shutdown Behavior ──"
    prompt_yn STOP_PLEX "  Stop Plex before backup (recommended)?" "$EX_STOP"

    if [[ "$STOP_PLEX" == "yes" ]]; then
        prompt_yn WAIT_FOR_STREAMS "  Wait for active streams to finish?" "$EX_WAIT"
        if [[ "$WAIT_FOR_STREAMS" == "yes" ]]; then
            prompt MAX_WAIT_MINUTES "  Max wait time in minutes" "$EX_WAIT_MIN"
        else
            MAX_WAIT_MINUTES=0
        fi
    else
        WAIT_FOR_STREAMS="no"
        MAX_WAIT_MINUTES=0
    fi
    echo ""

    # Email (use shared if already set, otherwise ask)
    if [[ -z "${SHARED_EMAIL_ENABLED:-}" ]]; then
        prompt_email "$EX_EMAIL" "$EX_EMAIL_TO"
    else
        EMAIL_ENABLED="$SHARED_EMAIL_ENABLED"
        EMAIL_TO="$SHARED_EMAIL_TO"
        echo "  📧 Using email settings from previous step: $EMAIL_ENABLED${EMAIL_TO:+ ($EMAIL_TO)}"
        echo ""
    fi

    # Schedule
    select_schedule 3 "backups"
    BACKUP_CRON_EXPR="$CRON_EXPR"
    BACKUP_CRON_DESC="$CRON_DESC"

    # --- Summary ---
    echo "  ── Backup Summary ──"
    echo "  Plex URL:     $PLEX_URL"
    echo "  Token:        ${PLEX_TOKEN:0:8}..."
    echo "  Backup dir:   $BACKUP_DIR"
    echo "  DB dir:       $PLEX_DB_DIR"
    echo "  Components:   $BACKUP_COMPONENTS"
    echo "  Retention:    $RETENTION_COUNT backups"
    echo "  Compression:  $COMPRESSION"
    echo "  Stop Plex:    $STOP_PLEX"
    echo "  Wait streams: $WAIT_FOR_STREAMS"
    echo "  Max wait:     ${MAX_WAIT_MINUTES}m"
    echo "  Email:        $EMAIL_ENABLED${EMAIL_TO:+ ($EMAIL_TO)}"
    echo "  Schedule:     $BACKUP_CRON_DESC"
    echo ""
}

write_backup_config() {
    cat > "$BACKUP_CONFIG" << CONF
###############################################################################
# Plex Backup Configuration
# Generated by installer on $(date '+%Y-%m-%d %H:%M:%S')
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
EMAIL_TO="${EMAIL_TO:-}"
EMAIL_FROM="plex-backup@$(hostname -f 2>/dev/null || hostname)"
EMAIL_SUBJECT_PREFIX="[Plex Backup]"
LOG_FILE="/var/log/plex-backup.log"
CONF
    chmod 600 "$BACKUP_CONFIG"
}

install_backup() {
    echo "  Installing backup tool..."
    cp "$SCRIPT_DIR/plex-backup.sh" "$INSTALL_DIR/plex-backup.sh"
    chmod 755 "$INSTALL_DIR/plex-backup.sh"
    echo "    ✅ Script → $INSTALL_DIR/plex-backup.sh"

    write_backup_config
    echo "    ✅ Config → $BACKUP_CONFIG"

    touch /var/log/plex-backup.log
    chmod 644 /var/log/plex-backup.log

    install_cron "plex-backup.sh" "/var/log/plex-backup.log" "$BACKUP_CRON_EXPR"
    echo "    ✅ Cron   → $BACKUP_CRON_DESC"
}

###############################################################################
# Main
###############################################################################

# Must be root
if [[ $EUID -ne 0 ]]; then
    echo "This installer must be run as root (sudo)."
    exit 1
fi

print_banner

# What to install
echo "What would you like to install?"
echo ""
echo "  1) 🔄 Auto-Updater only"
echo "  2) 💾 Backup only"
echo "  3) 🎬 Both (recommended)"
echo ""
read -rp "Select [3]: " INSTALL_CHOICE
INSTALL_CHOICE="${INSTALL_CHOICE:-3}"
echo ""

INSTALL_UPDATER=false
INSTALL_BACKUP=false

case "$INSTALL_CHOICE" in
    1) INSTALL_UPDATER=true ;;
    2) INSTALL_BACKUP=true ;;
    *) INSTALL_UPDATER=true; INSTALL_BACKUP=true ;;
esac

# Shared state
SHARED_TOKEN=""
SHARED_URL=""
SHARED_EMAIL_ENABLED=""
SHARED_EMAIL_TO=""

check_dependencies

# --- Setup ---
if $INSTALL_UPDATER; then
    setup_updater
fi

if $INSTALL_BACKUP; then
    setup_backup
fi

# --- Confirm ---
echo ""
echo "=============================================="
echo "  Ready to Install"
echo "=============================================="
echo ""
if $INSTALL_UPDATER; then
    echo "  🔄 Auto-Updater → $UPDATER_CRON_DESC"
fi
if $INSTALL_BACKUP; then
    echo "  💾 Backup        → $BACKUP_CRON_DESC"
fi
echo ""

read -rp "Proceed? (yes/no) [yes]: " confirm
confirm="${confirm:-yes}"

if [[ "$confirm" != "yes" && "$confirm" != "y" ]]; then
    echo "Aborted."
    exit 0
fi

# --- Install ---
echo ""
echo "Installing..."
echo ""
mkdir -p "$INSTALL_DIR"

if $INSTALL_UPDATER; then
    install_updater
    echo ""
fi

if $INSTALL_BACKUP; then
    install_backup
    echo ""
fi

# --- Done ---
echo "=============================================="
echo "  ✅ Installation Complete"
echo "=============================================="
echo ""

if $INSTALL_UPDATER; then
    echo "  🔄 Auto-Updater"
    echo "     Script:   $INSTALL_DIR/plex-autoupdate.sh"
    echo "     Config:   $UPDATER_CONFIG"
    echo "     Schedule: $UPDATER_CRON_DESC"
    echo "     Log:      /var/log/plex-autoupdate.log"
    echo "     Test:     sudo $INSTALL_DIR/plex-autoupdate.sh"
    echo ""
fi

if $INSTALL_BACKUP; then
    echo "  💾 Backup"
    echo "     Script:   $INSTALL_DIR/plex-backup.sh"
    echo "     Config:   $BACKUP_CONFIG"
    echo "     Schedule: $BACKUP_CRON_DESC"
    echo "     Log:      /var/log/plex-backup.log"
    echo "     Test:     sudo $INSTALL_DIR/plex-backup.sh"
    echo ""
fi
