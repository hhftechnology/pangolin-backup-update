#!/usr/bin/env bash

# Docker Update Configuration Management
# Handles loading, saving, and managing update automation configuration

# Default configuration values
readonly DEFAULT_UPDATE_CHECK_ENABLED=true
readonly DEFAULT_UPDATE_AUTO_UPDATE=false
readonly DEFAULT_UPDATE_NOTIFY_ONLY=false
readonly DEFAULT_UPDATE_INCLUDE_CONTAINERS=""
readonly DEFAULT_UPDATE_EXCLUDE_CONTAINERS=""
readonly DEFAULT_UPDATE_LABEL_FILTER=""
readonly DEFAULT_UPDATE_BACKUP_DAYS=7
readonly DEFAULT_UPDATE_AUTO_PRUNE=true
readonly DEFAULT_UPDATE_FORCE_RECREATE=false
readonly DEFAULT_UPDATE_REGISTRY_TIMEOUT=10
readonly DEFAULT_UPDATE_MIN_AGE=""
readonly DEFAULT_UPDATE_NOTIFY_ENABLED=false
readonly DEFAULT_UPDATE_NOTIFY_CHANNELS=""
readonly DEFAULT_UPDATE_USE_COMPOSE=true

# Configuration file paths
readonly SYSTEM_CONFIG_DIR="/etc/pangolin"
readonly USER_CONFIG_DIR="${HOME}/.pangolin"
readonly DEFAULT_CONFIG_FILE="${USER_CONFIG_DIR}/update.conf"

# Load configuration from file
load_update_config() {
    local config_file=${1:-${DEFAULT_CONFIG_FILE}}

    # Set defaults first
    UPDATE_CHECK_ENABLED="${DEFAULT_UPDATE_CHECK_ENABLED}"
    UPDATE_AUTO_UPDATE="${DEFAULT_UPDATE_AUTO_UPDATE}"
    UPDATE_NOTIFY_ONLY="${DEFAULT_UPDATE_NOTIFY_ONLY}"
    UPDATE_INCLUDE_CONTAINERS="${DEFAULT_UPDATE_INCLUDE_CONTAINERS}"
    UPDATE_EXCLUDE_CONTAINERS="${DEFAULT_UPDATE_EXCLUDE_CONTAINERS}"
    UPDATE_LABEL_FILTER="${DEFAULT_UPDATE_LABEL_FILTER}"
    UPDATE_BACKUP_DAYS="${DEFAULT_UPDATE_BACKUP_DAYS}"
    UPDATE_AUTO_PRUNE="${DEFAULT_UPDATE_AUTO_PRUNE}"
    UPDATE_FORCE_RECREATE="${DEFAULT_UPDATE_FORCE_RECREATE}"
    UPDATE_REGISTRY_TIMEOUT="${DEFAULT_UPDATE_REGISTRY_TIMEOUT}"
    UPDATE_MIN_AGE="${DEFAULT_UPDATE_MIN_AGE}"
    UPDATE_NOTIFY_ENABLED="${DEFAULT_UPDATE_NOTIFY_ENABLED}"
    UPDATE_NOTIFY_CHANNELS="${DEFAULT_UPDATE_NOTIFY_CHANNELS}"
    UPDATE_USE_COMPOSE="${DEFAULT_UPDATE_USE_COMPOSE}"

    # Notification service configs (will be loaded from file)
    UPDATE_GOTIFY_URL=""
    UPDATE_GOTIFY_TOKEN=""
    UPDATE_GOTIFY_PRIORITY=5

    UPDATE_NTFY_URL="https://ntfy.sh"
    UPDATE_NTFY_TOPIC=""
    UPDATE_NTFY_PRIORITY="default"
    UPDATE_NTFY_TOKEN=""

    UPDATE_DISCORD_WEBHOOK=""
    UPDATE_DISCORD_USERNAME="Docker Update Bot"

    UPDATE_TELEGRAM_BOT_TOKEN=""
    UPDATE_TELEGRAM_CHAT_ID=""

    UPDATE_SLACK_WEBHOOK=""
    UPDATE_SLACK_USERNAME="Docker Update Bot"

    UPDATE_EMAIL_SMTP_SERVER=""
    UPDATE_EMAIL_SMTP_PORT=587
    UPDATE_EMAIL_FROM=""
    UPDATE_EMAIL_TO=""
    UPDATE_EMAIL_USERNAME=""
    UPDATE_EMAIL_PASSWORD=""

    UPDATE_APPRISE_URL=""

    UPDATE_CUSTOM_SCRIPT=""

    # Try to load from system config first
    if [[ -f "${SYSTEM_CONFIG_DIR}/update.conf" && -r "${SYSTEM_CONFIG_DIR}/update.conf" ]]; then
        source "${SYSTEM_CONFIG_DIR}/update.conf"
        log "INFO" "Loaded system configuration from ${SYSTEM_CONFIG_DIR}/update.conf"
    fi

    # Then load from user config (overrides system config)
    if [[ -f "${config_file}" && -r "${config_file}" ]]; then
        source "${config_file}"
        log "INFO" "Loaded configuration from ${config_file}"
        return 0
    elif [[ "${config_file}" != "${DEFAULT_CONFIG_FILE}" ]]; then
        # Specific config file was requested but not found
        log "ERROR" "Configuration file not found: ${config_file}"
        return 1
    else
        log "INFO" "No user configuration file found. Using defaults."
        return 0
    fi
}

# Save configuration to file
save_update_config() {
    local config_file=${1:-${DEFAULT_CONFIG_FILE}}

    # Create config directory if it doesn't exist
    local config_dir=$(dirname "${config_file}")
    if [[ ! -d "${config_dir}" ]]; then
        mkdir -p "${config_dir}" || { log "ERROR" "Failed to create config directory: ${config_dir}"; return 1; }
    fi

    # Create config file
    cat > "${config_file}" << EOF
# Pangolin Docker Update Configuration
# Generated on $(date)

# ============================================================================
# GENERAL SETTINGS
# ============================================================================

# Enable automatic update checking
UPDATE_CHECK_ENABLED=${UPDATE_CHECK_ENABLED}

# Automatically apply updates without prompting
UPDATE_AUTO_UPDATE=${UPDATE_AUTO_UPDATE}

# Only check and notify, don't update
UPDATE_NOTIFY_ONLY=${UPDATE_NOTIFY_ONLY}

# Use docker-compose for container management (recommended)
UPDATE_USE_COMPOSE=${UPDATE_USE_COMPOSE}

# ============================================================================
# CONTAINER FILTERING
# ============================================================================

# Include only these containers (comma-separated, empty = all)
# Example: "pangolin,gerbil,traefik"
UPDATE_INCLUDE_CONTAINERS="${UPDATE_INCLUDE_CONTAINERS}"

# Exclude these containers (comma-separated)
# Example: "traefik,crowdsec"
UPDATE_EXCLUDE_CONTAINERS="${UPDATE_EXCLUDE_CONTAINERS}"

# Only update containers with this label (format: key=value)
# Example: "auto-update=true"
UPDATE_LABEL_FILTER="${UPDATE_LABEL_FILTER}"

# Only update containers older than this age (e.g., "7d", "2w", "1m")
# Leave empty to disable age filtering
UPDATE_MIN_AGE="${UPDATE_MIN_AGE}"

# ============================================================================
# UPDATE BEHAVIOR
# ============================================================================

# Backup images before updating (days to keep backups, 0 = no backup)
UPDATE_BACKUP_DAYS=${UPDATE_BACKUP_DAYS}

# Automatically prune dangling images after update
UPDATE_AUTO_PRUNE=${UPDATE_AUTO_PRUNE}

# Force recreate containers even if config hasn't changed
UPDATE_FORCE_RECREATE=${UPDATE_FORCE_RECREATE}

# Registry timeout in seconds
UPDATE_REGISTRY_TIMEOUT=${UPDATE_REGISTRY_TIMEOUT}

# ============================================================================
# NOTIFICATION SETTINGS
# ============================================================================

# Enable notifications
UPDATE_NOTIFY_ENABLED=${UPDATE_NOTIFY_ENABLED}

# Notification channels to use (comma-separated)
# Available: gotify, ntfy, discord, telegram, slack, email, apprise, custom
# Example: "gotify,discord,telegram"
UPDATE_NOTIFY_CHANNELS="${UPDATE_NOTIFY_CHANNELS}"

# ----------------------------------------------------------------------------
# Gotify Configuration
# ----------------------------------------------------------------------------
UPDATE_GOTIFY_URL="${UPDATE_GOTIFY_URL}"
UPDATE_GOTIFY_TOKEN="${UPDATE_GOTIFY_TOKEN}"
UPDATE_GOTIFY_PRIORITY=${UPDATE_GOTIFY_PRIORITY}

# ----------------------------------------------------------------------------
# ntfy Configuration
# ----------------------------------------------------------------------------
UPDATE_NTFY_URL="${UPDATE_NTFY_URL}"
UPDATE_NTFY_TOPIC="${UPDATE_NTFY_TOPIC}"
UPDATE_NTFY_PRIORITY="${UPDATE_NTFY_PRIORITY}"
UPDATE_NTFY_TOKEN="${UPDATE_NTFY_TOKEN}"

# ----------------------------------------------------------------------------
# Discord Configuration
# ----------------------------------------------------------------------------
UPDATE_DISCORD_WEBHOOK="${UPDATE_DISCORD_WEBHOOK}"
UPDATE_DISCORD_USERNAME="${UPDATE_DISCORD_USERNAME}"

# ----------------------------------------------------------------------------
# Telegram Configuration
# ----------------------------------------------------------------------------
UPDATE_TELEGRAM_BOT_TOKEN="${UPDATE_TELEGRAM_BOT_TOKEN}"
UPDATE_TELEGRAM_CHAT_ID="${UPDATE_TELEGRAM_CHAT_ID}"

# ----------------------------------------------------------------------------
# Slack Configuration
# ----------------------------------------------------------------------------
UPDATE_SLACK_WEBHOOK="${UPDATE_SLACK_WEBHOOK}"
UPDATE_SLACK_USERNAME="${UPDATE_SLACK_USERNAME}"

# ----------------------------------------------------------------------------
# Email Configuration
# ----------------------------------------------------------------------------
UPDATE_EMAIL_SMTP_SERVER="${UPDATE_EMAIL_SMTP_SERVER}"
UPDATE_EMAIL_SMTP_PORT=${UPDATE_EMAIL_SMTP_PORT}
UPDATE_EMAIL_FROM="${UPDATE_EMAIL_FROM}"
UPDATE_EMAIL_TO="${UPDATE_EMAIL_TO}"
UPDATE_EMAIL_USERNAME="${UPDATE_EMAIL_USERNAME}"
UPDATE_EMAIL_PASSWORD="${UPDATE_EMAIL_PASSWORD}"

# ----------------------------------------------------------------------------
# Apprise Configuration
# ----------------------------------------------------------------------------
# Apprise URL supports multiple services in one URL
# Example: "discord://webhook_id/webhook_token telegram://bot_token/chat_id"
UPDATE_APPRISE_URL="${UPDATE_APPRISE_URL}"

# ----------------------------------------------------------------------------
# Custom Script Configuration
# ----------------------------------------------------------------------------
# Path to custom notification script
# Script will receive JSON notification data via stdin
UPDATE_CUSTOM_SCRIPT="${UPDATE_CUSTOM_SCRIPT}"

EOF

    chmod 600 "${config_file}" || log "WARNING" "Could not set secure permissions on config file"
    log "SUCCESS" "Configuration saved to ${config_file}"
    return 0
}

# Interactive configuration wizard
configure_update_settings() {
    local exit_menu=false

    while [[ "${exit_menu}" == false ]]; do
        clear
        print_banner "DOCKER UPDATE AUTOMATION CONFIGURATION"

        printf "${CYAN}Current Configuration:${NC}\n"
        printf "1. Update Check:           ${YELLOW}%s${NC}\n" "$([ "${UPDATE_CHECK_ENABLED}" == "true" ] && echo "Enabled" || echo "Disabled")"
        printf "2. Auto Update:            ${YELLOW}%s${NC}\n" "$([ "${UPDATE_AUTO_UPDATE}" == "true" ] && echo "Enabled" || echo "Disabled")"
        printf "3. Notify Only:            ${YELLOW}%s${NC}\n" "$([ "${UPDATE_NOTIFY_ONLY}" == "true" ] && echo "Enabled" || echo "Disabled")"
        printf "4. Include Containers:     ${YELLOW}%s${NC}\n" "${UPDATE_INCLUDE_CONTAINERS:-All}"
        printf "5. Exclude Containers:     ${YELLOW}%s${NC}\n" "${UPDATE_EXCLUDE_CONTAINERS:-None}"
        printf "6. Label Filter:           ${YELLOW}%s${NC}\n" "${UPDATE_LABEL_FILTER:-None}"
        printf "7. Backup Days:            ${YELLOW}%s${NC}\n" "${UPDATE_BACKUP_DAYS}"
        printf "8. Auto Prune:             ${YELLOW}%s${NC}\n" "$([ "${UPDATE_AUTO_PRUNE}" == "true" ] && echo "Enabled" || echo "Disabled")"
        printf "9. Notifications:          ${YELLOW}%s${NC}\n" "$([ "${UPDATE_NOTIFY_ENABLED}" == "true" ] && echo "Enabled" || echo "Disabled")"
        printf "10. Notify Channels:       ${YELLOW}%s${NC}\n" "${UPDATE_NOTIFY_CHANNELS:-None}"

        printf "\n${CYAN}Options:${NC}\n"
        printf "1-10. Edit setting\n"
        printf "n.    Configure Notifications\n"
        printf "s.    Save Configuration\n"
        printf "q.    Return to Main Menu\n\n"

        printf "Enter your choice: "
        local choice
        read -r choice

        case "${choice}" in
            1)
                printf "Enable update checking? (y/n): "
                local enable
                read -r enable
                [[ "${enable,,}" == "y" ]] && UPDATE_CHECK_ENABLED=true || UPDATE_CHECK_ENABLED=false
                ;;
            2)
                printf "Enable automatic updates? (y/n): "
                local enable
                read -r enable
                [[ "${enable,,}" == "y" ]] && UPDATE_AUTO_UPDATE=true || UPDATE_AUTO_UPDATE=false
                ;;
            3)
                printf "Enable notify-only mode? (y/n): "
                local enable
                read -r enable
                [[ "${enable,,}" == "y" ]] && UPDATE_NOTIFY_ONLY=true || UPDATE_NOTIFY_ONLY=false
                ;;
            4)
                printf "Enter containers to include (comma-separated, empty for all): "
                read -r UPDATE_INCLUDE_CONTAINERS
                ;;
            5)
                printf "Enter containers to exclude (comma-separated): "
                read -r UPDATE_EXCLUDE_CONTAINERS
                ;;
            6)
                printf "Enter label filter (format: key=value): "
                read -r UPDATE_LABEL_FILTER
                ;;
            7)
                printf "Enter backup retention days (0 to disable): "
                local days
                read -r days
                [[ "${days}" =~ ^[0-9]+$ ]] && UPDATE_BACKUP_DAYS="${days}"
                ;;
            8)
                printf "Enable automatic pruning? (y/n): "
                local enable
                read -r enable
                [[ "${enable,,}" == "y" ]] && UPDATE_AUTO_PRUNE=true || UPDATE_AUTO_PRUNE=false
                ;;
            9)
                printf "Enable notifications? (y/n): "
                local enable
                read -r enable
                [[ "${enable,,}" == "y" ]] && UPDATE_NOTIFY_ENABLED=true || UPDATE_NOTIFY_ENABLED=false
                ;;
            10)
                printf "Enter notification channels (comma-separated):\n"
                printf "Available: gotify, ntfy, discord, telegram, slack, email, apprise, custom\n"
                printf "Channels: "
                read -r UPDATE_NOTIFY_CHANNELS
                ;;
            n|N)
                configure_notifications
                ;;
            s|S)
                save_update_config
                printf "\nPress Enter to continue..."
                read -r
                ;;
            q|Q)
                exit_menu=true
                ;;
            *)
                log "ERROR" "Invalid choice"
                sleep 1
                ;;
        esac
    done
}

# Configure notification services
configure_notifications() {
    local exit_menu=false

    while [[ "${exit_menu}" == false ]]; do
        clear
        print_banner "NOTIFICATION CONFIGURATION"

        printf "${CYAN}Available Notification Services:${NC}\n"
        printf "1. Gotify\n"
        printf "2. ntfy\n"
        printf "3. Discord\n"
        printf "4. Telegram\n"
        printf "5. Slack\n"
        printf "6. Email\n"
        printf "7. Apprise\n"
        printf "8. Custom Script\n"
        printf "9. Return to Update Configuration\n\n"

        printf "Enter your choice: "
        local choice
        read -r choice

        case "${choice}" in
            1) configure_gotify ;;
            2) configure_ntfy ;;
            3) configure_discord ;;
            4) configure_telegram ;;
            5) configure_slack ;;
            6) configure_email ;;
            7) configure_apprise ;;
            8) configure_custom_script ;;
            9) exit_menu=true ;;
            *) log "ERROR" "Invalid choice"; sleep 1 ;;
        esac
    done
}

# Individual notification service configurations
configure_gotify() {
    clear
    print_header "Gotify Configuration"
    printf "Enter Gotify URL (e.g., https://gotify.example.com): "
    read -r UPDATE_GOTIFY_URL
    printf "Enter Gotify Token: "
    read -r UPDATE_GOTIFY_TOKEN
    printf "Enter Priority (1-10, default 5): "
    read -r priority
    [[ "${priority}" =~ ^[0-9]+$ ]] && UPDATE_GOTIFY_PRIORITY="${priority}"
    log "SUCCESS" "Gotify configured"
    sleep 1
}

configure_ntfy() {
    clear
    print_header "ntfy Configuration"
    printf "Enter ntfy URL (default: https://ntfy.sh): "
    read -r url
    [[ -n "${url}" ]] && UPDATE_NTFY_URL="${url}"
    printf "Enter ntfy Topic: "
    read -r UPDATE_NTFY_TOPIC
    printf "Enter Priority (default/low/high): "
    read -r priority
    [[ -n "${priority}" ]] && UPDATE_NTFY_PRIORITY="${priority}"
    printf "Enter Access Token (optional): "
    read -r UPDATE_NTFY_TOKEN
    log "SUCCESS" "ntfy configured"
    sleep 1
}

configure_discord() {
    clear
    print_header "Discord Configuration"
    printf "Enter Discord Webhook URL: "
    read -r UPDATE_DISCORD_WEBHOOK
    printf "Enter Bot Username (default: Docker Update Bot): "
    read -r username
    [[ -n "${username}" ]] && UPDATE_DISCORD_USERNAME="${username}"
    log "SUCCESS" "Discord configured"
    sleep 1
}

configure_telegram() {
    clear
    print_header "Telegram Configuration"
    printf "Enter Telegram Bot Token: "
    read -r UPDATE_TELEGRAM_BOT_TOKEN
    printf "Enter Chat ID: "
    read -r UPDATE_TELEGRAM_CHAT_ID
    log "SUCCESS" "Telegram configured"
    sleep 1
}

configure_slack() {
    clear
    print_header "Slack Configuration"
    printf "Enter Slack Webhook URL: "
    read -r UPDATE_SLACK_WEBHOOK
    printf "Enter Bot Username (default: Docker Update Bot): "
    read -r username
    [[ -n "${username}" ]] && UPDATE_SLACK_USERNAME="${username}"
    log "SUCCESS" "Slack configured"
    sleep 1
}

configure_email() {
    clear
    print_header "Email Configuration"
    printf "Enter SMTP Server: "
    read -r UPDATE_EMAIL_SMTP_SERVER
    printf "Enter SMTP Port (default: 587): "
    read -r port
    [[ "${port}" =~ ^[0-9]+$ ]] && UPDATE_EMAIL_SMTP_PORT="${port}"
    printf "Enter From Email: "
    read -r UPDATE_EMAIL_FROM
    printf "Enter To Email: "
    read -r UPDATE_EMAIL_TO
    printf "Enter SMTP Username: "
    read -r UPDATE_EMAIL_USERNAME
    printf "Enter SMTP Password: "
    read -rs UPDATE_EMAIL_PASSWORD
    printf "\n"
    log "SUCCESS" "Email configured"
    sleep 1
}

configure_apprise() {
    clear
    print_header "Apprise Configuration"
    printf "Enter Apprise URL(s) (space-separated for multiple services):\n"
    printf "Example: discord://webhook_id/token telegram://bot_token/chat_id\n"
    printf "URL: "
    read -r UPDATE_APPRISE_URL
    log "SUCCESS" "Apprise configured"
    sleep 1
}

configure_custom_script() {
    clear
    print_header "Custom Script Configuration"
    printf "Enter path to custom notification script: "
    read -r UPDATE_CUSTOM_SCRIPT
    if [[ -n "${UPDATE_CUSTOM_SCRIPT}" && ! -x "${UPDATE_CUSTOM_SCRIPT}" ]]; then
        log "WARNING" "Script is not executable or doesn't exist"
    else
        log "SUCCESS" "Custom script configured"
    fi
    sleep 1
}

# Validate configuration
validate_update_config() {
    local valid=true

    # Check for conflicting settings
    if [[ "${UPDATE_AUTO_UPDATE}" == "true" && "${UPDATE_NOTIFY_ONLY}" == "true" ]]; then
        log "WARNING" "Both AUTO_UPDATE and NOTIFY_ONLY are enabled. NOTIFY_ONLY will take precedence."
        UPDATE_AUTO_UPDATE=false
    fi

    # Validate notification settings
    if [[ "${UPDATE_NOTIFY_ENABLED}" == "true" && -z "${UPDATE_NOTIFY_CHANNELS}" ]]; then
        log "WARNING" "Notifications enabled but no channels configured"
    fi

    return 0
}
