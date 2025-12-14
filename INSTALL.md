# Installation & Setup Guide

## Quick Installation

### Step 1: Clone or Download

```bash
# If using git
git clone https://github.com/hhftechnology/pangolin-backup-update.git
cd pangolin-backup-update

# Or download and extract manually
wget https://github.com/hhftechnology/pangolin-backup-update/archive/main.zip
unzip main.zip
cd pangolin-backup-update-main
```

### Step 2: Make Scripts Executable

```bash
chmod +x *.sh
```

### Step 3: Verify Installation

```bash
./backup-update-master.sh --help
./docker-update-check.sh --help
```

## Setting Up Docker Update Automation

### Step 1: Create Configuration Directory

```bash
mkdir -p ~/.pangolin
```

### Step 2: Copy Example Configuration

```bash
cp update.conf.example ~/.pangolin/update.conf
chmod 600 ~/.pangolin/update.conf
```

### Step 3: Edit Configuration

```bash
nano ~/.pangolin/update.conf
```

Or use the interactive wizard:

```bash
./docker-update-check.sh --configure
```

### Step 4: Test Your Setup

#### Test Update Detection

```bash
./docker-update-check.sh --dry-run
```

#### Test Notifications (if configured)

```bash
./docker-update-check.sh --test-notify
```

## Configuration Examples

### Example 1: Basic Monitoring (Recommended for Beginners)

```bash
# ~/.pangolin/update.conf

# Only notify about updates, don't apply them
UPDATE_NOTIFY_ONLY=true
UPDATE_NOTIFY_ENABLED=true
UPDATE_NOTIFY_CHANNELS="ntfy"

# ntfy configuration (free, no signup required)
UPDATE_NTFY_URL="https://ntfy.sh"
UPDATE_NTFY_TOPIC="my-docker-updates-$(hostname)"
UPDATE_NTFY_PRIORITY="default"
```

Test it:

```bash
# Subscribe to notifications on your phone
# Install ntfy app and subscribe to: my-docker-updates-yourhostname

# Send test notification
./docker-update-check.sh --test-notify

# Check for updates (will notify if any found)
./docker-update-check.sh
```

### Example 2: Conservative Auto-Update

```bash
# ~/.pangolin/update.conf

# Auto-update with safety features
UPDATE_AUTO_UPDATE=true
UPDATE_BACKUP_DAYS=14           # Keep backups for 2 weeks
UPDATE_AUTO_PRUNE=true          # Clean up old images
UPDATE_EXCLUDE_CONTAINERS="database,redis"  # Don't auto-update critical services
UPDATE_MIN_AGE="3d"             # Only update containers older than 3 days

# Notifications
UPDATE_NOTIFY_ENABLED=true
UPDATE_NOTIFY_CHANNELS="discord"
UPDATE_DISCORD_WEBHOOK="https://discord.com/api/webhooks/your-webhook"
```

### Example 3: Label-Based Selective Updates

1. Add labels to your docker-compose.yml:

```yaml
services:
  app:
    image: myapp:latest
    labels:
      - "auto-update=true" # Will be auto-updated

  database:
    image: postgres:15
    labels:
      - "auto-update=false" # Will NOT be auto-updated
```

2. Configure update automation:

```bash
# ~/.pangolin/update.conf
UPDATE_LABEL_FILTER="auto-update=true"
UPDATE_AUTO_UPDATE=true
UPDATE_BACKUP_DAYS=7
UPDATE_AUTO_PRUNE=true
```

## Setting Up Notifications

### Gotify (Self-Hosted)

1. Install Gotify server: https://gotify.net/docs/install

2. Create application and get token

3. Configure:

```bash
UPDATE_NOTIFY_CHANNELS="gotify"
UPDATE_GOTIFY_URL="https://gotify.yourdomain.com"
UPDATE_GOTIFY_TOKEN="your-app-token"
UPDATE_GOTIFY_PRIORITY=5
```

### ntfy (Easiest, No Setup Required)

1. Install ntfy app on your phone

2. Choose a unique topic name

3. Configure:

```bash
UPDATE_NOTIFY_CHANNELS="ntfy"
UPDATE_NTFY_URL="https://ntfy.sh"
UPDATE_NTFY_TOPIC="my-unique-topic-$(hostname)"
UPDATE_NTFY_PRIORITY="default"
```

4. Subscribe to the topic in your app

### Discord

1. Create webhook in Discord server settings

2. Configure:

```bash
UPDATE_NOTIFY_CHANNELS="discord"
UPDATE_DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."
UPDATE_DISCORD_USERNAME="Docker Update Bot"
```

### Telegram

1. Create bot with @BotFather

2. Get chat ID (send message to bot, then visit: https://api.telegram.org/bot<TOKEN>/getUpdates)

3. Configure:

```bash
UPDATE_NOTIFY_CHANNELS="telegram"
UPDATE_TELEGRAM_BOT_TOKEN="your-bot-token"
UPDATE_TELEGRAM_CHAT_ID="your-chat-id"
```

### Email

```bash
UPDATE_NOTIFY_CHANNELS="email"
UPDATE_EMAIL_SMTP_SERVER="smtp.gmail.com"
UPDATE_EMAIL_SMTP_PORT=587
UPDATE_EMAIL_FROM="your-email@gmail.com"
UPDATE_EMAIL_TO="recipient@example.com"
UPDATE_EMAIL_USERNAME="your-email@gmail.com"
UPDATE_EMAIL_PASSWORD="your-app-password"  # Use app-specific password for Gmail
```

### Multiple Channels

```bash
UPDATE_NOTIFY_CHANNELS="discord,telegram,ntfy"
# Configure each service separately
```

## Setting Up Cron Jobs

### Edit Crontab

```bash
crontab -e
```

### Example Cron Jobs

#### Daily Update Check (9 AM, Notify Only)

```cron
0 9 * * * /path/to/docker-update-check.sh --notify-only --config ~/.pangolin/update.conf >> /var/log/docker-updates.log 2>&1
```

#### Weekly Auto-Update (Sunday 2 AM)

```cron
0 2 * * 0 /path/to/docker-update-check.sh --auto --backup-days 7 --prune --config ~/.pangolin/update.conf >> /var/log/docker-updates.log 2>&1
```

#### Hourly Check for Critical Containers

```cron
0 * * * * /path/to/docker-update-check.sh --include "pangolin,gerbil" --notify-only >> /var/log/docker-updates.log 2>&1
```

#### Daily Backup (Midnight)

```cron
0 0 * * * /path/to/backup-update-master.sh --cron backup >> /var/log/pangolin-backup.log 2>&1
```

### Verify Cron Jobs

```bash
# List current cron jobs
crontab -l

# Check cron logs
grep CRON /var/log/syslog

# Check application logs
tail -f /var/log/docker-updates.log
```

## Verification Checklist

After installation, verify everything works:

- [ ] Scripts are executable (`ls -l *.sh`)
- [ ] Configuration file exists (`ls -l ~/.pangolin/update.conf`)
- [ ] Configuration file has secure permissions (`ls -l ~/.pangolin/update.conf` shows 600)
- [ ] Update check runs without errors (`./docker-update-check.sh --dry-run`)
- [ ] Notifications work (`./docker-update-check.sh --test-notify`)
- [ ] Cron jobs are scheduled (`crontab -l`)
- [ ] Logs are being written (`ls -l /var/log/docker-updates.log`)

## Troubleshooting Installation

### "Permission denied" errors

```bash
# Make scripts executable
chmod +x *.sh

# Or add to docker group
sudo usermod -aG docker $USER
newgrp docker
```

### "Docker not found" errors

```bash
# Install Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

# Install docker-compose
sudo apt-get install docker-compose-plugin
```

### "curl: command not found"

```bash
# Ubuntu/Debian
sudo apt-get install curl

# CentOS/RHEL
sudo yum install curl
```

### Configuration file not loading

```bash
# Check file exists
ls -la ~/.pangolin/update.conf

# Check file permissions
chmod 600 ~/.pangolin/update.conf

# Verify syntax (should not show errors)
bash -n ~/.pangolin/update.conf
```

## Next Steps

1. **Test in dry-run mode** - Run `./docker-update-check.sh --dry-run` to see what would be updated
2. **Set up notifications** - Configure at least one notification channel and test it
3. **Schedule cron jobs** - Set up automated checks and backups
4. **Monitor logs** - Check logs regularly to ensure everything works
5. **Create backups** - Run a manual backup before enabling auto-updates

## Getting Help

- Check the main README.md for detailed documentation
- Review example configurations in `update.conf.example`
- Test with `--dry-run` flag before making changes
- Enable verbose logging by checking `/tmp/docker-update-check.log`

## Uninstallation

```bash
# Remove cron jobs
crontab -e
# Delete relevant lines

# Remove configuration
rm -rf ~/.pangolin

# Remove backup images (optional)
docker images | grep dockcheck | awk '{print $1":"$2}' | xargs docker rmi

# Remove scripts
cd ..
rm -rf pangolin-backup-update
```
