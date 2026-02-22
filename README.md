# Plex Auto-Updater

Automatically checks for new Plex Media Server versions, waits for active streams to finish, then safely downloads, installs, and restarts Plex — all unattended.

Works with both **Plex Pass beta** builds and **public stable** releases on Ubuntu/Debian systems.

## Features

- **Channel selection** — choose between Plex Pass beta or public stable releases
- **Stream-aware** — checks for active sessions before updating; waits for viewers to finish
- **Configurable timeout** — set how long to wait for streams before giving up
- **Safe rollback** — restarts the old version if installation fails
- **Lock file** — prevents overlapping runs when triggered by cron
- **Email notifications** — optional alerts for updates, errors, and completions
- **Zero downtime goal** — downloads the update while streams are still active, only stops Plex when nobody is watching

## How It Works

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

## Requirements

- Ubuntu or Debian-based Linux
- Plex Media Server installed via `.deb`
- `curl`, `python3`, `dpkg`, `systemctl`
- A [Plex authentication token](https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/)
- *(Optional)* `mailutils` or `sendmail` for email notifications

## Quick Start

```bash
# Clone the repo
git clone https://github.com/biggux/plex-autoupdate.git
cd plex-autoupdate

# Run the interactive installer (as root)
sudo bash install-plex-updater.sh
```

The installer will prompt you for:

1. Your **Plex token**
2. **Update channel** — public (stable) or plexpass (beta)
3. **Email notifications** — enable/disable and set recipient
4. **Wait timeout** — how long to wait for active streams

It installs the script to `/opt/plex-autoupdate/`, writes your config to `/etc/plex-autoupdate.conf`, and sets up a cron job to run every 6 hours.

## Manual Setup

If you prefer to configure things yourself:

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

# Add to cron (runs every 6 hours)
sudo crontab -e
# Add: 0 */6 * * * /opt/plex-autoupdate/plex-autoupdate.sh >> /var/log/plex-autoupdate.log 2>&1
```

## Configuration

All settings live in `/etc/plex-autoupdate.conf`:

| Setting | Default | Description |
|---|---|---|
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

## Usage

```bash
# Run manually with default config
sudo /opt/plex-autoupdate/plex-autoupdate.sh

# Run with a custom config file
sudo /opt/plex-autoupdate/plex-autoupdate.sh --config /path/to/my.conf

# Check logs
tail -f /var/log/plex-autoupdate.log
```

## Email Notifications

When enabled, you'll receive emails for:

- New version detected (with version numbers)
- Update completed successfully
- Update postponed (streams still active after timeout)
- Errors (download failures, install failures, Plex won't start)

Requires `mailutils` or `sendmail`:

```bash
sudo apt install mailutils
```

## Logs

All activity is logged to `/var/log/plex-autoupdate.log` with timestamps:

```
[2026-02-22 03:00:01] [INFO] ===== Plex Auto-Update Check Started [Channel: Public (stable)] =====
[2026-02-22 03:00:01] [INFO] Installed version: 1.40.0.8227
[2026-02-22 03:00:02] [INFO] Checking Public (stable) channel for updates...
[2026-02-22 03:00:03] [INFO] Latest Public (stable) version: 1.41.0.8451
[2026-02-22 03:00:03] [INFO] New version available: 1.41.0.8451 (current: 1.40.0.8227)
[2026-02-22 03:00:08] [INFO] Downloaded to: /tmp/plex-update/plexmediaserver_1.41.0.8451_amd64.deb
[2026-02-22 03:00:08] [INFO] Active sessions: 2. Waiting... (0s / 21600s)
[2026-02-22 03:04:08] [INFO] No active sessions. Proceeding with update.
[2026-02-22 03:04:13] [INFO] Plex stopped.
[2026-02-22 03:04:18] [INFO] Installation successful.
[2026-02-22 03:04:28] [INFO] Plex is running. Version: 1.41.0.8451
[2026-02-22 03:04:28] [INFO] ===== Update complete: 1.40.0.8227 -> 1.41.0.8451 =====
```

## License

MIT