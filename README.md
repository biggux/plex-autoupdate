# 🎬 Plex Auto-Updater & Backup

Two tools for automated Plex Media Server management on Ubuntu/Debian systems:

- **[🔄 Auto-Updater](#-plex-auto-updater)** — Automatically checks for new Plex versions, waits for active streams to finish, then safely downloads, installs, and restarts Plex.
- **[💾 Backup](#-plex-backup)** — Automated backup of Plex databases, preferences, and plugin data with stream-aware scheduling, configurable retention, and optional compression.

Both tools share the same stream-aware design: they wait for active viewers to finish before taking action. 🍿

## 📋 Requirements

* Ubuntu or Debian-based Linux
* Plex Media Server installed via `.deb`
* `curl`, `python3`, `dpkg`, `systemctl`, `cron`
* A [Plex authentication token](https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/)
* *(Optional)* `mailutils` or `sendmail` for email notifications

## 🚀 Quick Start

```bash
# Clone the repo
git clone https://github.com/biggux/plex-autoupdate.git
cd plex-autoupdate

# Run the interactive installer
sudo bash install.sh
```

The installer lets you choose what to set up:

```
  1) 🔄 Auto-Updater only
  2) 💾 Backup only
  3) 🎬 Both (recommended)
```

Shared settings like your Plex token, server URL, and email preferences are configured once and reused across both tools.

---

# 🔄 Plex Auto-Updater

Automatically checks for new Plex Media Server versions, waits for active streams to finish, then safely downloads, installs, and restarts Plex — all unattended.

Works with both **Plex Pass beta** builds and **public stable** releases.

## ✨ Auto-Updater Features

* 📡 **Channel selection** — choose between Plex Pass beta or public stable releases
* 👀 **Stream-aware** — checks for active sessions before updating; waits for viewers to finish
* ⏱️ **Configurable timeout** — set how long to wait for streams before giving up
* 📅 **Flexible scheduling** — daily, twice daily, every 6 hours, hourly, weekly, or custom cron
* 🔙 **Safe rollback** — restarts the old version if installation fails
* 🔒 **Lock file** — prevents overlapping runs when triggered by cron
* 📧 **Email notifications** — optional alerts for updates, errors, and completions
* ⚡ **Zero downtime goal** — downloads the update while streams are still active, only stops Plex when nobody is watching

## 🔧 How It Works

```
┌─────────────────────────────┐
│  Check latest version       │
│  (plex.tv API)              │
└─────────────┬───────────────┘
              │
              ▼
        ┌───────────┐    Yes
        │ Up to date?├─────────► Exit
        └─────┬─────┘
              │ No
              ▼
┌─────────────────────────────┐
│  Download .deb package      │
│  (while streams may be      │
│   still active)             │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  Anyone watching?           │
│  ├─ Yes → wait & re-check  │
│  │        (every 2 min)     │
│  └─ No  → continue         │
└─────────────┬───────────────┘
              │
              ▼
┌─────────────────────────────┐
│  Stop → Install → Start    │
└─────────────────────────────┘
```

## 🛠️ Manual Setup (Auto-Updater)

If you prefer not to use the installer:

```bash
# Copy files
sudo mkdir -p /opt/plex-autoupdate
sudo cp plex-autoupdate.sh /opt/plex-autoupdate/
sudo chmod 755 /opt/plex-autoupdate/plex-autoupdate.sh

# Create config
sudo cp plex-autoupdate.conf /etc/plex-autoupdate.conf
sudo chmod 600 /etc/plex-autoupdate.conf

# Edit config with your values
sudo nano /etc/plex-autoupdate.conf

# Add to cron (example: daily at 2 AM)
sudo crontab -e
# Add: 0 2 * * * /opt/plex-autoupdate/plex-autoupdate.sh >> /var/log/plex-autoupdate.log 2>&1
```

## ⚙️ Auto-Updater Configuration

All settings live in `/etc/plex-autoupdate.conf`:

| Setting | Default | Description |
| --- | --- | --- |
| `PLEX_TOKEN` | *(required)* | Your Plex authentication token |
| `PLEX_URL` | `http://localhost:32400` | Plex server address |
| `UPDATE_CHANNEL` | `public` | `public` for stable, `plexpass` for beta |
| `MAX_WAIT_MINUTES` | `360` | Max time to wait for active streams (minutes) |
| `CHECK_INTERVAL_SECONDS` | `120` | How often to re-check for streams while waiting |
| `EMAIL_ENABLED` | `no` | `yes` to enable email notifications |
| `EMAIL_TO` | *(empty)* | Recipient email address |
| `EMAIL_FROM` | auto-detected | Sender address |
| `EMAIL_SUBJECT_PREFIX` | `[Plex Updater]` | Email subject prefix |
| `LOG_FILE` | `/var/log/plex-autoupdate.log` | Log file path |

## 📅 Update Schedule Options

The installer offers these preset schedules:

| Option | Cron Expression | Description |
| --- | --- | --- |
| Daily (default) | `0 2 * * *` | Once per day at 2:00 AM |
| Twice daily | `0 2,14 * * *` | At 2:00 AM and 2:00 PM |
| Every 6 hours | `0 */6 * * *` | Four times per day |
| Weekly | `0 2 * * 0` | Sunday at 2:00 AM |
| Custom | *(you provide)* | Any valid cron expression |

To change the schedule after installation:

```bash
sudo crontab -e
```

Or re-run the installer — it will detect and replace the existing cron entry.

## 💻 Usage (Auto-Updater)

```bash
# Run manually with default config
sudo /opt/plex-autoupdate/plex-autoupdate.sh

# Run with a custom config file
sudo /opt/plex-autoupdate/plex-autoupdate.sh --config /path/to/my.conf

# Check logs
tail -f /var/log/plex-autoupdate.log
```

## 📝 Example Log Output (Auto-Updater)

```
[2026-02-22 02:00:01] [INFO] ===== Plex Auto-Update Check Started [Channel: Public (stable)] =====
[2026-02-22 02:00:01] [INFO] Installed version: 1.40.0.8227
[2026-02-22 02:00:02] [INFO] Checking Public (stable) channel for updates...
[2026-02-22 02:00:03] [INFO] Latest Public (stable) version: 1.41.0.8451
[2026-02-22 02:00:03] [INFO] New version available: 1.41.0.8451 (current: 1.40.0.8227)
[2026-02-22 02:00:08] [INFO] Downloaded to: /tmp/plex-update/plexmediaserver_1.41.0.8451_amd64.deb
[2026-02-22 02:00:08] [INFO] Active sessions: 2. Waiting... (0s / 21600s)
[2026-02-22 02:04:08] [INFO] No active sessions. Proceeding with update.
[2026-02-22 02:04:13] [INFO] Plex stopped.
[2026-02-22 02:04:18] [INFO] Installation successful.
[2026-02-22 02:04:28] [INFO] Plex is running. Version: 1.41.0.8451
[2026-02-22 02:04:28] [INFO] ===== Update complete: 1.40.0.8227 -> 1.41.0.8451 =====
```

---

# 💾 Plex Backup

Automated backup of Plex databases, preferences, and plugin data with stream-aware scheduling, configurable retention, and optional compression.

## ✨ Backup Features

* 🧩 **Configurable components** — back up databases, Preferences.xml, and/or plugin data
* 👀 **Stream-aware** — waits for active viewers to finish before stopping Plex
* 🛡️ **Safe shutdown** — stops Plex for consistent database copies, restarts automatically
* 📦 **Compression** — optional gzip for smaller backup archives
* 🗑️ **Retention policy** — automatically prune old backups
* 📧 **Email notifications** — optional alerts on success, errors, or skipped backups
* 🔒 **Lock file** — prevents overlapping backup runs

## 🔧 How It Works

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

## 🛠️ Manual Setup (Backup)

If you prefer not to use the installer:

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

## ⚙️ Backup Configuration

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

## 📅 Backup Schedule Options

| Option | Cron Expression | Description |
| --- | --- | --- |
| Daily (default) | `0 3 * * *` | Once per day at 3:00 AM |
| Twice daily | `0 3,15 * * *` | At 3:00 AM and 3:00 PM |
| Every 6 hours | `0 */6 * * *` | Four times per day |
| Weekly | `0 3 * * 0` | Sunday at 3:00 AM |
| Custom | *(you provide)* | Any valid cron expression |

## 💻 Usage (Backup)

```bash
# Run manually
sudo /opt/plex-autoupdate/plex-backup.sh

# Run with custom config
sudo /opt/plex-autoupdate/plex-backup.sh --config /path/to/my.conf

# Check logs
tail -f /var/log/plex-backup.log
```

## 📝 Example Log Output (Backup)

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

---

## 📧 Email Notifications

Both tools support email notifications. When enabled, you'll receive emails for:

**🔄 Auto-Updater:**
* ✅ New version detected (with version numbers)
* ✅ Update completed successfully
* ⏸️ Update postponed (streams still active after timeout)
* ❌ Errors (download failures, install failures, Plex won't start)

**💾 Backup:**
* ✅ Backup completed successfully (with file size)
* ⏸️ Backup skipped (streams still active after timeout)
* ❌ Backup completed with errors

Requires `mailutils` or `sendmail`:

```bash
sudo apt install mailutils
```

## 📄 Logs

Both tools log with timestamps to separate files:

* **🔄 Auto-Updater:** `/var/log/plex-autoupdate.log`
* **💾 Backup:** `/var/log/plex-backup.log`

## 📜 License

MIT
