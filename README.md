# Pangolin Backup & Update Management

## Features

### Core Features

- **Automated Backups** - Scheduled backups of Docker compose configurations and data
- **Easy Restore** - Simple restoration from any backup point
- **Retention Management** - Automatic cleanup of old backups
- **Interactive & CLI Modes** - Full menu-driven interface or command-line usage

### Docker Update Automation (NEW!)

- **Automatic Update Detection** - Checks Docker registries for new image versions
- **Selective Updates** - Include/exclude containers, label-based filtering
- **Notification System** - Multi-channel notifications (Gotify, Discord, Telegram, ntfy, Slack, Email, Apprise)
- **Safe Updates** - Image backups before updating with configurable retention
- **Auto-Prune** - Automatic cleanup of dangling images
- **Flexible Scheduling** - Cron-ready for automated update checks
- **Dry-Run Mode** - Test updates without making changes

## Quick Start

### Installation

1. Clone the repository:

```bash
git clone https://github.com/hhftechnology/pangolin-backup-update.git
cd pangolin-backup-update
```

2. Make scripts executable:

```bash
chmod +x *.sh
```

3. Run the interactive menu:

```bash
./backup-update-master.sh
```

### Basic Usage

#### Interactive Mode

```bash
./backup-update-master.sh
```

#### Command-Line Mode

**Backup Operations:**

```bash
# Create backup
./backup-update-master.sh backup

# Restore from latest backup
./backup-update-master.sh restore

# Delete specific backup
./backup-update-master.sh delete 2
```

**Manual Updates:**

```bash
# Update stack without CrowdSec
./backup-update-master.sh update-basic

# Update stack with CrowdSec
./backup-update-master.sh update-full
```

**Automated Update Checks:**

```bash
# Check for available updates
./docker-update-check.sh

# Auto-update all containers
./docker-update-check.sh --auto

# Check and notify only (no updates)
./docker-update-check.sh --notify-only

# Update with backup and prune
./docker-update-check.sh --auto --backup-days 7 --prune

# Exclude specific containers
./docker-update-check.sh --exclude "traefik,crowdsec"

# Include only specific containers
./docker-update-check.sh --include "pangolin,gerbil"

# Update containers with specific label
./docker-update-check.sh --label "auto-update=true" --auto

# Dry run (see what would be updated)
./docker-update-check.sh --dry-run

# Interactive configuration wizard
./docker-update-check.sh --configure

# Test notification setup
./docker-update-check.sh --test-notify
```

## Docker Update Automation

### Configuration

1. **Copy example configuration:**

```bash
mkdir -p ~/.pangolin
cp update.conf.example ~/.pangolin/update.conf
```

2. **Edit configuration:**

```bash
nano ~/.pangolin/update.conf
```

3. **Or use interactive wizard:**

```bash
./docker-update-check.sh --configure
```

### Configuration Options

#### General Settings

- `UPDATE_CHECK_ENABLED` - Enable/disable update checking
- `UPDATE_AUTO_UPDATE` - Automatically apply updates without prompting
- `UPDATE_NOTIFY_ONLY` - Only check and notify, don't update
- `UPDATE_USE_COMPOSE` - Use docker-compose for container management

#### Filtering Options

- `UPDATE_INCLUDE_CONTAINERS` - Comma-separated list of containers to include (empty = all)
- `UPDATE_EXCLUDE_CONTAINERS` - Comma-separated list of containers to exclude
- `UPDATE_LABEL_FILTER` - Only update containers with specific label (e.g., "auto-update=true")
- `UPDATE_MIN_AGE` - Only update containers older than specified age (e.g., "7d", "2w")

#### Update Behavior

- `UPDATE_BACKUP_DAYS` - Keep image backups for N days (0 = no backup)
- `UPDATE_AUTO_PRUNE` - Automatically prune dangling images after update
- `UPDATE_FORCE_RECREATE` - Force recreate containers even if config unchanged
- `UPDATE_REGISTRY_TIMEOUT` - Registry query timeout in seconds

#### Notification Settings

- `UPDATE_NOTIFY_ENABLED` - Enable/disable notifications
- `UPDATE_NOTIFY_CHANNELS` - Comma-separated list of notification channels

### Notification Services

#### Gotify

```bash
UPDATE_GOTIFY_URL="https://gotify.example.com"
UPDATE_GOTIFY_TOKEN="your-token"
UPDATE_GOTIFY_PRIORITY=5
```

#### ntfy

```bash
UPDATE_NTFY_URL="https://ntfy.sh"
UPDATE_NTFY_TOPIC="docker-updates"
UPDATE_NTFY_PRIORITY="high"
UPDATE_NTFY_TOKEN="optional-access-token"
```

#### Discord

```bash
UPDATE_DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."
UPDATE_DISCORD_USERNAME="Docker Update Bot"
```

#### Telegram

```bash
UPDATE_TELEGRAM_BOT_TOKEN="your-bot-token"
UPDATE_TELEGRAM_CHAT_ID="your-chat-id"
```

#### Slack

```bash
UPDATE_SLACK_WEBHOOK="https://hooks.slack.com/services/..."
UPDATE_SLACK_USERNAME="Docker Update Bot"
```

#### Email

```bash
UPDATE_EMAIL_SMTP_SERVER="smtp.gmail.com"
UPDATE_EMAIL_SMTP_PORT=587
UPDATE_EMAIL_FROM="sender@example.com"
UPDATE_EMAIL_TO="recipient@example.com"
UPDATE_EMAIL_USERNAME="smtp-username"
UPDATE_EMAIL_PASSWORD="smtp-password"
```

#### Apprise (Multi-Service)

```bash
# Install apprise: pip install apprise
UPDATE_APPRISE_URL="discord://webhook_id/token telegram://bot_token/chat_id"
```

#### Custom Script

```bash
UPDATE_CUSTOM_SCRIPT="/path/to/notification-script.sh"
# Script receives JSON via stdin:
# {"title":"...","message":"...","timestamp":"...","updates":{...}}
```

### Label-Based Selective Updates

Add labels to your `docker-compose.yml`:

```yaml
services:
  pangolin:
    image: fosrl/pangolin:latest
    labels:
      - "auto-update=true"

  traefik:
    image: traefik:latest
    labels:
      - "auto-update=false"
```

Then use label filtering:

```bash
./docker-update-check.sh --label "auto-update=true" --auto
```

### Cron Automation

#### Check for updates daily, notify only

```bash
crontab -e
# Add:
0 9 * * * /path/to/docker-update-check.sh --notify-only --config ~/.pangolin/update.conf >> /var/log/docker-updates.log 2>&1
```

#### Auto-update weekly with backup and prune

```bash
# Every Sunday at 2 AM
0 2 * * 0 /path/to/docker-update-check.sh --auto --backup-days 7 --prune --config ~/.pangolin/update.conf >> /var/log/docker-updates.log 2>&1
```

#### Check specific containers daily

```bash
# Check only critical services
0 10 * * * /path/to/docker-update-check.sh --include "pangolin,gerbil" --notify-only >> /var/log/docker-updates.log 2>&1
```

### Backup & Rollback

#### Image Backups

When `UPDATE_BACKUP_DAYS` is set, images are automatically backed up before updates:

```bash
# Backups are tagged as: dockcheck/container:YYYY-MM-DD_HHMM_tag
docker images | grep dockcheck
```

#### Rollback

To rollback to a previous image:

```bash
# 1. List backup images
./docker-update-check.sh --list-backups

# 2. Stop container
docker-compose stop container-name

# 3. Retag backup as current
docker tag dockcheck/container:2024-01-15_1430_v1.0 original-image:tag

# 4. Restart container
docker-compose up -d container-name
```

#### Cleanup old backups

```bash
# Remove backups older than 30 days
./docker-update-check.sh --cleanup-backups 30
```

## Advanced Usage

### Example Scenarios

#### Scenario 1: Conservative Production Setup

```bash
# Monitor all containers, notify but don't auto-update
UPDATE_NOTIFY_ONLY=true
UPDATE_NOTIFY_ENABLED=true
UPDATE_NOTIFY_CHANNELS="discord,email"
UPDATE_BACKUP_DAYS=30
UPDATE_EXCLUDE_CONTAINERS="critical-db"
UPDATE_MIN_AGE="7d"
```

#### Scenario 2: Aggressive Development Setup

```bash
# Auto-update everything except critical services
UPDATE_AUTO_UPDATE=true
UPDATE_EXCLUDE_CONTAINERS="database,redis"
UPDATE_BACKUP_DAYS=7
UPDATE_AUTO_PRUNE=true
UPDATE_NOTIFY_ENABLED=true
UPDATE_NOTIFY_CHANNELS="gotify"
```

#### Scenario 3: Label-Based Selective Auto-Update

```bash
# Only auto-update containers with auto-update=true label
UPDATE_LABEL_FILTER="auto-update=true"
UPDATE_AUTO_UPDATE=true
UPDATE_BACKUP_DAYS=14
UPDATE_NOTIFY_ENABLED=true
UPDATE_NOTIFY_CHANNELS="telegram"
```

### Testing Notifications

Before relying on notifications, test your setup:

```bash
./docker-update-check.sh --test-notify
```

## Troubleshooting

### Update Detection Issues

**Problem:** Can't detect updates for custom registry

```bash
# Check if image digest is available
docker manifest inspect your-image:tag

# Test registry connectivity
curl -I https://your-registry.com/v2/
```

**Problem:** Rate limiting from Docker Hub

```bash
# Login to Docker Hub for higher rate limits
docker login

# Or use regctl (recommended by dockcheck)
# https://github.com/regclient/regclient
```

### Notification Issues

**Problem:** Notifications not sending

```bash
# Test individual notification service
./docker-update-check.sh --test-notify

# Check logs
tail -f /tmp/docker-update-check.log

# Verify service configuration
grep UPDATE_ ~/.pangolin/update.conf
```

### Permission Issues

**Problem:** Can't access Docker

```bash
# Add user to docker group
sudo usermod -aG docker $USER
newgrp docker

# Or run with sudo
sudo ./docker-update-check.sh
```

## Files Overview

- `backup-update-master.sh` - Main entry point with interactive menu
- `backup-ba-up-ma.sh` - Backup and restore functions
- `update-ba-up-ma.sh` - Manual update functions
- `docker-update-check.sh` - Automated update detection (NEW!)
- `docker-update-utils.sh` - Update utility functions (NEW!)
- `docker-update-config.sh` - Configuration management (NEW!)
- `docker-update-notify.sh` - Notification system (NEW!)
- `utils-ba-up-ma.sh` - Common utility functions
- `config-ba-up-ma.sh` - Configuration management
- `cron-ba-up-ma.sh` - Cron job setup
- `update.conf.example` - Example configuration file (NEW!)

## Requirements

### Core Requirements

- bash 4.0+
- docker / docker-compose
- tar, grep, awk, sed

### Optional (for enhanced features)

- curl (for update detection and notifications)
- jq (for JSON parsing)
- regctl (for better registry queries, respects rate limits)
- apprise (for multi-service notifications)
- sendmail/msmtp (for email notifications)

## Security Considerations

1. **Configuration Files** - Store sensitive data securely

   ```bash
   chmod 600 ~/.pangolin/update.conf
   ```

2. **Webhook URLs** - Keep webhook URLs private, rotate regularly

3. **SMTP Passwords** - Consider using app-specific passwords

4. **Auto-Updates** - Test thoroughly before enabling in production

5. **Backup Verification** - Regularly test restore procedures

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is open source and available under the MIT License.


## Support

For issues, questions, or suggestions:

- Open an issue on GitHub
- Check existing documentation
- Review example configurations

---

**Note:** Always test in a non-production environment first. While image backups provide rollback capability, testing is the best way to ensure smooth updates.
