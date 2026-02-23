---

# Plex Backup

Automated backup of Plex databases, preferences, and plugin data with stream-aware scheduling, configurable retention, and optional compression.

## Features

* **Configurable components** — back up databases, Preferences.xml, and/or plugin data
* **Stream-aware** — waits for active viewers to finish before stopping Plex
* **Safe shutdown** — stops Plex for consistent database copies, restarts automatically
* **Compression** — optional gzip for smaller backup archives
* **Retention policy** — automatically prune old backups
* **Email notifications** — optional alerts on success, errors, or skipped backups
* **Lock file** — prevents overlapping backup runs

## How It Works

```
┌─────────────────────────────┐
│  Check for active streams   │
│  (if configured to wait)    │
└─────────────┬───────────────┘
              │
              ▼
        ┌───────────┐    Timeout
        │ Streams?  ├──────────► Skip backup
        └─────┬─────┘
              │ None
              ▼
┌─────────────────────────────┐
│  Stop Plex (if configured)  │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  Copy: databases,           │
│  preferences, plugins       │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  Start Plex                 │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  Compress → enforce         │
│  retention → notify         │
└─────────────────────────────┘
```

## Quick Start

```bash
# From the repo directory
sudo bash install-plex-backup.sh
```

The installer will prompt you for:

1. Your **Plex token**
2. **Backup destination** — any local or mounted path
3. **Components** — database, preferences, plugins
4. **Retention** — how many backups to keep
5. **Shutdown behavior** — stop Plex and/or wait for streams
6. **Email notifications** — enable/disable and set recipient
7. **Schedule** — how often to run backups

## Manual Setup

```bash
# Copy files
sudo cp plex-backup.sh /opt/plex-autoupdate/
sudo chmod 755 /opt/plex-autoupdate/plex-backup.sh

# Create config
sudo cp plex-backup.conf /etc/plex-backup.conf
sudo chmod 600 /etc/plex-backup.conf

# Edit config with your values
sudo nano /etc/plex-backup.conf

# Add to cron (example: daily at 3 AM)
sudo crontab -e
# Add: 0 3 * * * /opt/plex-autoupdate/plex-backup.sh >> /var/log/plex-backup.log 2>&1
```

## Backup Configuration

All settings live in `/etc/plex-backup.conf`:

| Setting | Default | Description |
| --- | --- | --- |
| `PLEX_TOKEN` | *(required)* | Your Plex authentication token |
| `PLEX_URL` | `http://localhost:32400` | Plex server address |
| `BACKUP_DIR` | *(required)* | Where to store backups |
| `BACKUP_COMPONENTS` | `database preferences plugins` | What to back up |
| `PLEX_DB_DIR` | `/var/lib/plexmediaserver/db-local` | Plex database directory |
| `RETENTION_COUNT` | `7` | Backups to keep (0 = unlimited) |
| `STOP_PLEX` | `yes` | Stop Plex before backup |
| `WAIT_FOR_STREAMS` | `yes` | Wait for viewers to finish |
| `MAX_WAIT_MINUTES` | `60` | Timeout for waiting |
| `COMPRESSION` | `gzip` | `gzip` or `none` |
| `EMAIL_ENABLED` | `no` | Enable email alerts |
| `LOG_FILE` | `/var/log/plex-backup.log` | Log file path |

## Backup Schedule Options

| Option | Cron Expression | Description |
| --- | --- | --- |
| Daily (default) | `0 3 * * *` | Once per day at 3:00 AM |
| Twice daily | `0 3,15 * * *` | At 3:00 AM and 3:00 PM |
| Every 6 hours | `0 */6 * * *` | Four times per day |
| Weekly | `0 3 * * 0` | Sunday at 3:00 AM |
| Custom | *(you provide)* | Any valid cron expression |

## Usage

```bash
# Run manually
sudo /opt/plex-autoupdate/plex-backup.sh

# Run with custom config
sudo /opt/plex-autoupdate/plex-backup.sh --config /path/to/my.conf

# Check logs
tail -f /var/log/plex-backup.log
```

## Example Log Output

```
[2026-02-23 03:00:01] [INFO] ===== Plex Backup Started =====
[2026-02-23 03:00:01] [INFO] Backup destination: /mnt/tank/backups/plex
[2026-02-23 03:00:01] [INFO] Components: database preferences plugins
[2026-02-23 03:00:02] [INFO] No active sessions. Proceeding.
[2026-02-23 03:00:02] [INFO] Stopping Plex Media Server...
[2026-02-23 03:00:05] [INFO] Plex stopped.
[2026-02-23 03:00:05] [INFO] Backing up databases from /var/lib/plexmediaserver/db-local...
[2026-02-23 03:00:09] [INFO] Database backup complete: 4 files, 4.4G
[2026-02-23 03:00:09] [INFO] Backing up Preferences.xml...
[2026-02-23 03:00:09] [INFO] Preferences backup complete.
[2026-02-23 03:00:09] [INFO] Backing up plugin data...
[2026-02-23 03:00:12] [INFO] Plugin backup complete: 156M
[2026-02-23 03:00:12] [INFO] Starting Plex Media Server...
[2026-02-23 03:00:17] [INFO] Plex is running.
[2026-02-23 03:00:17] [INFO] Compressing backup...
[2026-02-23 03:00:45] [INFO] Compressed to plex-backup-20260223-030001.tar.gz (2.1G)
[2026-02-23 03:00:45] [INFO] Enforcing retention policy: keeping last 7 backups...
[2026-02-23 03:00:45] [INFO] Backup complete: plex-backup-20260223-030001.tar.gz (2.1G)
[2026-02-23 03:00:45] [INFO] ===== Plex Backup Finished Successfully =====
```
