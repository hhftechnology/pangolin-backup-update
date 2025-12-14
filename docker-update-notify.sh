#!/usr/bin/env bash

# Docker Update Notification System
# Plugin-based notification system supporting multiple services

# Send notifications through configured channels
send_notifications() {
    local title=$1
    local message=$2
    local priority=${3:-normal}
    local updates_json=${4:-"{}"}

    if [[ "${UPDATE_NOTIFY_ENABLED}" != "true" ]]; then
        return 0
    fi

    if [[ -z "${UPDATE_NOTIFY_CHANNELS}" ]]; then
        log "WARNING" "No notification channels configured"
        return 0
    fi

    # Parse channels
    IFS=',' read -ra CHANNELS <<< "${UPDATE_NOTIFY_CHANNELS}"

    local sent_count=0
    local failed_count=0
    local -a succeeded_channels=()
    local -a failed_channels=()

    for channel in "${CHANNELS[@]}"; do
        channel=$(echo "${channel}" | xargs)  # trim whitespace
        [[ -z "${channel}" ]] && continue

        case "${channel}" in
            gotify)
                if send_gotify_notification "${title}" "${message}" "${priority}"; then
                    sent_count=$((sent_count + 1))
                    succeeded_channels+=("${channel}")
                else
                    failed_count=$((failed_count + 1))
                    failed_channels+=("${channel}")
                fi
                ;;
            ntfy)
                if send_ntfy_notification "${title}" "${message}" "${priority}"; then
                    sent_count=$((sent_count + 1))
                    succeeded_channels+=("${channel}")
                else
                    failed_count=$((failed_count + 1))
                    failed_channels+=("${channel}")
                fi
                ;;
            discord)
                if send_discord_notification "${title}" "${message}" "${updates_json}"; then
                    sent_count=$((sent_count + 1))
                    succeeded_channels+=("${channel}")
                else
                    failed_count=$((failed_count + 1))
                    failed_channels+=("${channel}")
                fi
                ;;
            telegram)
                if send_telegram_notification "${title}" "${message}"; then
                    sent_count=$((sent_count + 1))
                    succeeded_channels+=("${channel}")
                else
                    failed_count=$((failed_count + 1))
                    failed_channels+=("${channel}")
                fi
                ;;
            slack)
                if send_slack_notification "${title}" "${message}" "${updates_json}"; then
                    sent_count=$((sent_count + 1))
                    succeeded_channels+=("${channel}")
                else
                    failed_count=$((failed_count + 1))
                    failed_channels+=("${channel}")
                fi
                ;;
            email)
                if send_email_notification "${title}" "${message}"; then
                    sent_count=$((sent_count + 1))
                    succeeded_channels+=("${channel}")
                else
                    failed_count=$((failed_count + 1))
                    failed_channels+=("${channel}")
                fi
                ;;
            apprise)
                if send_apprise_notification "${title}" "${message}"; then
                    sent_count=$((sent_count + 1))
                    succeeded_channels+=("${channel}")
                else
                    failed_count=$((failed_count + 1))
                    failed_channels+=("${channel}")
                fi
                ;;
            custom)
                if send_custom_notification "${title}" "${message}" "${updates_json}"; then
                    sent_count=$((sent_count + 1))
                    succeeded_channels+=("${channel}")
                else
                    failed_count=$((failed_count + 1))
                    failed_channels+=("${channel}")
                fi
                ;;
            *)
                log "WARNING" "Unknown notification channel: ${channel}"
                failed_count=$((failed_count + 1))
                failed_channels+=("${channel}")
                ;;
        esac
    done

    # Report results with details
    if [[ ${sent_count} -gt 0 ]]; then
        log "SUCCESS" "Notifications sent: ${succeeded_channels[*]}"

        # Only show info about failures if some channels worked
        if [[ ${failed_count} -gt 0 ]]; then
            log "INFO" "Some channels failed: ${failed_channels[*]}"
        fi
        return 0
    elif [[ ${failed_count} -gt 0 ]]; then
        # All notifications failed
        log "ERROR" "All notification channels failed: ${failed_channels[*]}"
        return 1
    else
        # No channels configured or processed
        log "WARNING" "No notification channels configured"
        return 1
    fi
}

# Gotify notification
send_gotify_notification() {
    local title=$1
    local message=$2
    local priority=${3:-normal}

    if [[ -z "${UPDATE_GOTIFY_URL}" || -z "${UPDATE_GOTIFY_TOKEN}" ]]; then
        log "ERROR" "Gotify not configured (missing URL or token)"
        return 1
    fi

    # Convert priority to gotify format (1-10)
    local gotify_priority=${UPDATE_GOTIFY_PRIORITY:-5}

    # Build JSON payload
    local payload=$(cat <<EOF
{
  "title": "${title}",
  "message": "${message}",
  "priority": ${gotify_priority}
}
EOF
)

    # Send notification
    local response=$(curl -fsSL -X POST "${UPDATE_GOTIFY_URL}/message" \
        -H "X-Gotify-Key: ${UPDATE_GOTIFY_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${payload}" 2>&1)

    if [[ $? -eq 0 ]]; then
        log "INFO" "Gotify notification sent"
        return 0
    else
        log "ERROR" "Failed to send Gotify notification: ${response}"
        return 1
    fi
}

# ntfy notification
send_ntfy_notification() {
    local title=$1
    local message=$2
    local priority=${3:-default}

    if [[ -z "${UPDATE_NTFY_TOPIC}" ]]; then
        log "ERROR" "ntfy not configured (missing topic)"
        return 1
    fi

    local ntfy_url="${UPDATE_NTFY_URL:-https://ntfy.sh}"
    local ntfy_priority="${UPDATE_NTFY_PRIORITY:-default}"

    # Build headers
    local headers=(-H "Title: ${title}" -H "Priority: ${ntfy_priority}")

    if [[ -n "${UPDATE_NTFY_TOKEN}" ]]; then
        headers+=(-H "Authorization: Bearer ${UPDATE_NTFY_TOKEN}")
    fi

    # Send notification
    local response=$(curl -fsSL -X POST "${ntfy_url}/${UPDATE_NTFY_TOPIC}" \
        "${headers[@]}" \
        -d "${message}" 2>&1)

    if [[ $? -eq 0 ]]; then
        log "INFO" "ntfy notification sent"
        return 0
    else
        log "ERROR" "Failed to send ntfy notification: ${response}"
        return 1
    fi
}

# Discord notification
send_discord_notification() {
    local title=$1
    local message=$2
    local updates_json=${3:-"{}"}

    if [[ -z "${UPDATE_DISCORD_WEBHOOK}" ]]; then
        log "ERROR" "Discord not configured (missing webhook URL)"
        return 1
    fi

    local username="${UPDATE_DISCORD_USERNAME:-Docker Update Bot}"

    # Escape JSON special characters in message
    local escaped_message=$(echo "${message}" | sed 's/"/\\"/g' | sed 's/\n/\\n/g')

    # Build JSON payload with embed
    local payload=$(cat <<EOF
{
  "username": "${username}",
  "embeds": [{
    "title": "${title}",
    "description": "${escaped_message}",
    "color": 3447003,
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  }]
}
EOF
)

    # Send notification
    local response=$(curl -fsSL -X POST "${UPDATE_DISCORD_WEBHOOK}" \
        -H "Content-Type: application/json" \
        -d "${payload}" 2>&1)

    if [[ $? -eq 0 ]]; then
        log "INFO" "Discord notification sent"
        return 0
    else
        log "ERROR" "Failed to send Discord notification: ${response}"
        return 1
    fi
}

# Telegram notification
send_telegram_notification() {
    local title=$1
    local message=$2

    if [[ -z "${UPDATE_TELEGRAM_BOT_TOKEN}" || -z "${UPDATE_TELEGRAM_CHAT_ID}" ]]; then
        log "ERROR" "Telegram not configured (missing bot token or chat ID)"
        return 1
    fi

    # Format message with HTML
    local formatted_message="<b>${title}</b>%0A%0A${message}"

    # URL encode the message
    formatted_message=$(echo -n "${formatted_message}" | sed 's/ /%20/g' | sed 's/\n/%0A/g')

    # Send notification
    local api_url="https://api.telegram.org/bot${UPDATE_TELEGRAM_BOT_TOKEN}/sendMessage"
    local response=$(curl -fsSL -X POST "${api_url}" \
        -d "chat_id=${UPDATE_TELEGRAM_CHAT_ID}" \
        -d "text=${formatted_message}" \
        -d "parse_mode=HTML" 2>&1)

    if [[ $? -eq 0 ]] && echo "${response}" | grep -q '"ok":true'; then
        log "INFO" "Telegram notification sent"
        return 0
    else
        log "ERROR" "Failed to send Telegram notification: ${response}"
        return 1
    fi
}

# Slack notification
send_slack_notification() {
    local title=$1
    local message=$2
    local updates_json=${3:-"{}"}

    if [[ -z "${UPDATE_SLACK_WEBHOOK}" ]]; then
        log "ERROR" "Slack not configured (missing webhook URL)"
        return 1
    fi

    local username="${UPDATE_SLACK_USERNAME:-Docker Update Bot}"

    # Escape JSON special characters
    local escaped_message=$(echo "${message}" | sed 's/"/\\"/g' | sed 's/\n/\\n/g')

    # Build JSON payload
    local payload=$(cat <<EOF
{
  "username": "${username}",
  "blocks": [
    {
      "type": "header",
      "text": {
        "type": "plain_text",
        "text": "${title}"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "${escaped_message}"
      }
    }
  ]
}
EOF
)

    # Send notification
    local response=$(curl -fsSL -X POST "${UPDATE_SLACK_WEBHOOK}" \
        -H "Content-Type: application/json" \
        -d "${payload}" 2>&1)

    if [[ $? -eq 0 ]]; then
        log "INFO" "Slack notification sent"
        return 0
    else
        log "ERROR" "Failed to send Slack notification: ${response}"
        return 1
    fi
}

# Email notification
send_email_notification() {
    local title=$1
    local message=$2

    if [[ -z "${UPDATE_EMAIL_SMTP_SERVER}" || -z "${UPDATE_EMAIL_FROM}" || -z "${UPDATE_EMAIL_TO}" ]]; then
        log "ERROR" "Email not configured (missing SMTP server, from, or to address)"
        return 1
    fi

    # Create email content
    local email_body=$(cat <<EOF
Subject: ${title}
From: ${UPDATE_EMAIL_FROM}
To: ${UPDATE_EMAIL_TO}
Content-Type: text/plain; charset=UTF-8

${message}

---
Sent by Pangolin Docker Update Automation
$(date)
EOF
)

    # Try to send using different methods
    local sent=false

    # Method 1: Try sendmail
    if command -v sendmail >/dev/null 2>&1; then
        echo "${email_body}" | sendmail -t && sent=true
    fi

    # Method 2: Try msmtp
    if [[ "${sent}" == "false" ]] && command -v msmtp >/dev/null 2>&1; then
        echo "${email_body}" | msmtp --host="${UPDATE_EMAIL_SMTP_SERVER}" \
            --port="${UPDATE_EMAIL_SMTP_PORT}" \
            --from="${UPDATE_EMAIL_FROM}" \
            --auth=on \
            --user="${UPDATE_EMAIL_USERNAME}" \
            --passwordeval="echo ${UPDATE_EMAIL_PASSWORD}" \
            "${UPDATE_EMAIL_TO}" && sent=true
    fi

    # Method 3: Try curl with SMTP
    if [[ "${sent}" == "false" ]] && command -v curl >/dev/null 2>&1; then
        local smtp_url="smtp://${UPDATE_EMAIL_SMTP_SERVER}:${UPDATE_EMAIL_SMTP_PORT}"
        echo "${email_body}" | curl -fsSL --url "${smtp_url}" \
            --mail-from "${UPDATE_EMAIL_FROM}" \
            --mail-rcpt "${UPDATE_EMAIL_TO}" \
            --user "${UPDATE_EMAIL_USERNAME}:${UPDATE_EMAIL_PASSWORD}" \
            --upload-file - && sent=true
    fi

    if [[ "${sent}" == "true" ]]; then
        log "INFO" "Email notification sent"
        return 0
    else
        log "ERROR" "Failed to send email notification (no working email client found)"
        return 1
    fi
}

# Apprise notification
send_apprise_notification() {
    local title=$1
    local message=$2

    if [[ -z "${UPDATE_APPRISE_URL}" ]]; then
        log "ERROR" "Apprise not configured (missing URL)"
        return 1
    fi

    if ! command -v apprise >/dev/null 2>&1; then
        log "ERROR" "Apprise CLI not installed (install with: pip install apprise)"
        return 1
    fi

    # Send notification using apprise CLI
    apprise -t "${title}" -b "${message}" ${UPDATE_APPRISE_URL} 2>&1

    if [[ $? -eq 0 ]]; then
        log "INFO" "Apprise notification sent"
        return 0
    else
        log "ERROR" "Failed to send Apprise notification"
        return 1
    fi
}

# Custom script notification
send_custom_notification() {
    local title=$1
    local message=$2
    local updates_json=${3:-"{}"}

    if [[ -z "${UPDATE_CUSTOM_SCRIPT}" ]]; then
        log "ERROR" "Custom script not configured"
        return 1
    fi

    if [[ ! -x "${UPDATE_CUSTOM_SCRIPT}" ]]; then
        log "ERROR" "Custom script not found or not executable: ${UPDATE_CUSTOM_SCRIPT}"
        return 1
    fi

    # Build JSON payload
    local payload=$(cat <<EOF
{
  "title": "${title}",
  "message": "${message}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "updates": ${updates_json}
}
EOF
)

    # Execute custom script with JSON via stdin
    echo "${payload}" | "${UPDATE_CUSTOM_SCRIPT}" 2>&1

    if [[ $? -eq 0 ]]; then
        log "INFO" "Custom notification script executed"
        return 0
    else
        log "ERROR" "Failed to execute custom notification script"
        return 1
    fi
}

# Build update summary message
build_update_message() {
    local updates_available=$1
    shift
    local update_list=("$@")

    if [[ ${updates_available} -eq 0 ]]; then
        echo "All Docker containers are up to date. No updates available."
        return 0
    fi

    local message="Docker Updates Available: ${updates_available}\n\n"

    for update_info in "${update_list[@]}"; do
        # Parse: container_name|image|current_digest|new_digest
        IFS='|' read -r container image current_digest new_digest <<< "${update_info}"
        message+="Container: ${container}\n"
        message+="Image: ${image}\n"
        message+="Status: Update available\n\n"
    done

    echo -e "${message}"
}

# Build update completion message
build_completion_message() {
    local updated_count=$1
    local failed_count=$2
    shift 2
    local updated_list=("$@")

    local message=""

    if [[ ${updated_count} -gt 0 ]]; then
        message="Successfully updated ${updated_count} container(s):\n\n"
        for container in "${updated_list[@]}"; do
            message+="✓ ${container}\n"
        done
    fi

    if [[ ${failed_count} -gt 0 ]]; then
        message+="\nFailed to update ${failed_count} container(s)\n"
    fi

    echo -e "${message}"
}

# Test notification configuration
test_notifications() {
    log "INFO" "Testing notification configuration..."

    local title="Pangolin Docker Update - Test Notification"
    local message="This is a test notification from Pangolin Docker Update Automation.\n\nTimestamp: $(date)\n\nIf you received this, your notification configuration is working correctly."

    send_notifications "${title}" "${message}" "normal" "{}"

    log "INFO" "Test notification sent"
}
