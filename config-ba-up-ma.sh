#!/usr/bin/env bash

# Configuration management for Pangolin stack

# Load configuration
load_config() {
    BACKUP_DIR="${DEFAULT_BACKUP_DIR}"
    RETENTION_DAYS="${DEFAULT_RETENTION_DAYS}"
    BACKUP_ITEMS=("${DEFAULT_BACKUP_ITEMS[@]}")
    LOG_FILE="${BACKUP_DIR}/pangolin-backup.log"
    
    if [[ -f "${CONFIG_FILE}" && -r "${CONFIG_FILE}" ]]; then
        source "${CONFIG_FILE}"
        log "INFO" "Configuration loaded from ${CONFIG_FILE}"
    else
        log "INFO" "No configuration file found. Using defaults."
        save_config
    fi
}

# Save configuration
save_config() {
    if [[ "${DRY_RUN}" == true ]]; then
        log "INFO" "DRY-RUN: Would save configuration to ${CONFIG_FILE}"
        return 0
    fi
    
    mkdir -p "$(dirname "${CONFIG_FILE}")" 2>/dev/null || true
    {
        printf "# Pangolin Backup Configuration\n"
        printf "# Generated on %s\n\n" "$(date)"
        printf "BACKUP_DIR=\"%s\"\n\n" "${BACKUP_DIR}"
        printf "RETENTION_DAYS=\"%s\"\n\n" "${RETENTION_DAYS}"
        printf "BACKUP_ITEMS=(" 
        for item in "${BACKUP_ITEMS[@]}"; do
            printf "\"%s\" " "${item}"
        done
        printf ")\n"
    } > "${CONFIG_FILE}" || { log "ERROR" "Failed to save configuration to ${CONFIG_FILE}"; return 1; }
    
    chmod 600 "${CONFIG_FILE}" || log "WARNING" "Could not set secure permissions on config file"
    log "SUCCESS" "Configuration saved to ${CONFIG_FILE}"
    return 0
}

# Configure backup settings
configure_backup() {
    local exit_menu=false
    while [[ "${exit_menu}" == false ]]; do
        clear
        print_banner "BACKUP CONFIGURATION"
        printf "${CYAN}Current Configuration:${NC}\n"
        printf "1. Backup Directory:  ${YELLOW}%s${NC}\n" "${BACKUP_DIR}"
        printf "2. Retention Period:  ${YELLOW}%d days${NC}\n" "${RETENTION_DAYS}"
        printf "3. Backup Items:      ${YELLOW}%d items${NC}\n" "${#BACKUP_ITEMS[@]}"
        printf "\n${CYAN}Options:${NC}\n"
        printf "1. Change Backup Directory\n"
        printf "2. Change Retention Period\n"
        printf "3. Manage Backup Items\n"
        printf "4. Save Configuration\n"
        printf "5. Return to Main Menu\n"
        printf "6. Cancel (Discard Changes)\n\n"
        printf "Enter your choice [1-6]: "
        local choice
        read -r choice
        
        case "${choice}" in
            1)
                printf "Enter new backup directory path (or 'c' to cancel): "
                local new_dir
                read -r new_dir
                [[ "${new_dir,,}" == "c" ]] && { printf "Operation cancelled.\n"; sleep 1; continue; }
                new_dir="${new_dir/#\~/$HOME}"
                if [[ "${DRY_RUN}" == true ]]; then
                    log "INFO" "DRY-RUN: Would change backup directory to: ${new_dir}"
                    BACKUP_DIR="${new_dir}"
                    LOG_FILE="${BACKUP_DIR}/pangolin-backup.log"
                elif mkdir -p "${new_dir}" 2>/dev/null && [[ -w "${new_dir}" ]]; then
                    BACKUP_DIR="${new_dir}"
                    LOG_FILE="${BACKUP_DIR}/pangolin-backup.log"
                    log "SUCCESS" "Backup directory changed to: ${BACKUP_DIR}"
                else
                    log "ERROR" "Could not create or write to directory: ${new_dir}"
                fi
                ;;
            2)
                printf "Enter new retention period in days (current: %d) or 'c' to cancel: " "${RETENTION_DAYS}"
                local new_retention
                read -r new_retention
                [[ "${new_retention,,}" == "c" ]] && { printf "Operation cancelled.\n"; sleep 1; continue; }
                [[ "${new_retention}" =~ ^[0-9]+$ && "${new_retention}" -gt 0 ]] && { RETENTION_DAYS="${new_retention}"; log "SUCCESS" "Retention period changed to: ${RETENTION_DAYS} days"; } || log "ERROR" "Invalid retention period."
                ;;
            3) manage_backup_items ;;
            4) save_config ;;
            5) 
                local config_changed=false
                [[ -f "${CONFIG_FILE}" && -r "${CONFIG_FILE}" ]] && { source "${CONFIG_FILE}" 2>/dev/null; [[ "${BACKUP_DIR}" != "${DEFAULT_BACKUP_DIR}" || "${RETENTION_DAYS}" != "${DEFAULT_RETENTION_DAYS}" ]] && config_changed=true; }
                if [[ "${config_changed}" == true ]]; then
                    printf "${YELLOW}You have unsaved changes. Save before returning? (y/n):${NC} "
                    local save_confirm
                    read -r save_confirm
                    [[ "${save_confirm,,}" == "y" ]] && save_config
                fi
                exit_menu=true
                ;;
            6)
                printf "${YELLOW}Are you sure you want to discard any changes? (y/n):${NC} "
                local confirm
                read -r confirm
                [[ "${confirm,,}" == "y" ]] && { load_config; log "INFO" "Changes discarded."; exit_menu=true; }
                ;;
            *) log "ERROR" "Invalid choice."; sleep 2 ;;
        esac
        [[ "${exit_menu}" == false ]] && { printf "\nPress Enter to continue..."; read -r; }
    done
}

# Manage backup items
manage_backup_items() {
    local exit_submenu=false
    while [[ "${exit_submenu}" == false ]]; do
        clear
        print_header "MANAGE BACKUP ITEMS"
        printf "${CYAN}Current Backup Items:${NC}\n"
        if [[ ${#BACKUP_ITEMS[@]} -eq 0 ]]; then
            printf "  No items configured.\n"
        else
            for i in "${!BACKUP_ITEMS[@]}"; do
                printf "  ${YELLOW}[%d]${NC} %s\n" "${i}" "${BACKUP_ITEMS[$i]}"
            done
        fi
        printf "\n${CYAN}Options:${NC}\n"
        printf "1. Add Item\n"
        printf "2. Remove Item\n"
        printf "3. Clear All Items\n"
        printf "4. Restore Default Items\n"
        printf "5. Return to Configuration Menu\n"
        printf "6. Cancel (Discard Changes)\n\n"
        printf "Enter your choice [1-6]: "
        local choice
        read -r choice
        
        case "${choice}" in
            1)
                printf "Enter path to add (relative to Pangolin directory) or 'c' to cancel: "
                local new_item
                read -r new_item
                [[ "${new_item,,}" == "c" ]] && { printf "Operation cancelled.\n"; sleep 1; continue; }
                if [[ -n "${new_item}" ]]; then
                    local exists=false
                    for item in "${BACKUP_ITEMS[@]}"; do
                        [[ "${item}" == "${new_item}" ]] && exists=true && break
                    done
                    [[ "${exists}" == true ]] && log "WARNING" "Item already exists: ${new_item}" || { BACKUP_ITEMS+=("${new_item}"); log "SUCCESS" "Added item: ${new_item}"; }
                else
                    log "ERROR" "Item path cannot be empty."
                fi
                ;;
            2)
                [[ ${#BACKUP_ITEMS[@]} -eq 0 ]] && { log "WARNING" "No items to remove."; } || {
                    printf "Enter index of item to remove or 'c' to cancel: "
                    local index
                    read -r index
                    [[ "${index,,}" == "c" ]] && { printf "Operation cancelled.\n"; sleep 1; continue; }
                    if [[ "${index}" =~ ^[0-9]+$ && "${index}" -lt "${#BACKUP_ITEMS[@]}" ]]; then
                        local removed_item="${BACKUP_ITEMS[$index]}"
                        local new_items=()
                        for i in "${!BACKUP_ITEMS[@]}"; do
                            [[ "${i}" -ne "${index}" ]] && new_items+=("${BACKUP_ITEMS[$i]}")
                        done
                        BACKUP_ITEMS=("${new_items[@]}")
                        log "SUCCESS" "Removed item: ${removed_item}"
                    else
                        log "ERROR" "Invalid index: ${index}"
                    fi
                }
                ;;
            3)
                printf "Are you sure you want to clear all items? (y/n/c): "
                local confirm
                read -r confirm
                [[ "${confirm,,}" == "c" ]] && { printf "Operation cancelled.\n"; sleep 1; continue; }
                [[ "${confirm,,}" == "y" ]] && { BACKUP_ITEMS=(); log "SUCCESS" "Cleared all backup items."; }
                ;;
            4)
                printf "Are you sure you want to restore default items? (y/n/c): "
                local confirm
                read -r confirm
                [[ "${confirm,,}" == "c" ]] && { printf "Operation cancelled.\n"; sleep 1; continue; }
                [[ "${confirm,,}" == "y" ]] && { BACKUP_ITEMS=("${DEFAULT_BACKUP_ITEMS[@]}"); log "SUCCESS" "Restored default backup items."; }
                ;;
            5) exit_submenu=true ;;
            6)
                printf "${YELLOW}Are you sure you want to discard any changes? (y/n):${NC} "
                local confirm
                read -r confirm
                [[ "${confirm,,}" == "y" ]] && { local temp_items=(); [[ -f "${CONFIG_FILE}" && -r "${CONFIG_FILE}" ]] && { source "${CONFIG_FILE}" 2>/dev/null; temp_items=("${BACKUP_ITEMS[@]}"); } || temp_items=("${DEFAULT_BACKUP_ITEMS[@]}"); BACKUP_ITEMS=("${temp_items[@]}"); log "INFO" "Changes discarded."; exit_submenu=true; }
                ;;
            *) log "ERROR" "Invalid choice."; sleep 2 ;;
        esac
        [[ "${exit_submenu}" == false ]] && { printf "\nPress Enter to continue..."; read -r; }
    done
}