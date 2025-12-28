#!/usr/bin/env bash

# Cron job setup for Pangolin stack backups

setup_cron_job() {
    print_header "CRON JOB SETUP"
    # Get the actual script path - try backup-update-master.sh first, then fallback to master.sh
    local script_path=""
    if [[ -f "${SCRIPT_DIR}/backup-update-master.sh" ]]; then
        script_path=$(readlink -f "${SCRIPT_DIR}/backup-update-master.sh" 2>/dev/null || realpath "${SCRIPT_DIR}/backup-update-master.sh" 2>/dev/null || echo "${SCRIPT_DIR}/backup-update-master.sh")
    elif [[ -f "${SCRIPT_DIR}/master.sh" ]]; then
        script_path=$(readlink -f "${SCRIPT_DIR}/master.sh" 2>/dev/null || realpath "${SCRIPT_DIR}/master.sh" 2>/dev/null || echo "${SCRIPT_DIR}/master.sh")
    else
        log "ERROR" "Could not find backup script in ${SCRIPT_DIR}"; return 1
    fi
    
    # Get the script basename for pattern matching
    local script_basename=$(basename "${script_path}")
    
    printf "${CYAN}This will setup a cron job to automatically run backups.${NC}\n\n"
    printf "${CYAN}Current cron jobs for this script:${NC}\n"
    # Search for cron jobs containing the actual script path or basename
    local current_cron=$(crontab -l 2>/dev/null | grep -F "${script_basename}" || crontab -l 2>/dev/null | grep -F "${script_path}" || true)
    [[ -n "$current_cron" ]] && printf "%s\n" "$current_cron" || printf "  No cron jobs found.\n"
    printf "\n${CYAN}Schedule Options:${NC}\n"
    printf "1. Daily (at midnight)\n"
    printf "2. Every 3 days (at midnight)\n"
    printf "3. Weekly (Sunday at midnight)\n"
    printf "4. Custom schedule\n"
    printf "5. Remove existing cron job\n"
    printf "6. Cancel\n\n"
    printf "Enter your choice [1-6]: "
    local choice
    read -r choice
    
    case "${choice}" in
        1) local schedule="0 0 * * *" description="daily at midnight" ;;
        2) local schedule="0 0 */3 * *" description="every 3 days at midnight" ;;
        3) local schedule="0 0 * * 0" description="weekly on Sunday at midnight" ;;
        4)
            printf "Enter cron schedule expression (e.g., '0 2 */3 * *') or 'c' to cancel: "
            local custom_schedule
            read -r custom_schedule
            [[ "${custom_schedule,,}" == "c" || -z "${custom_schedule}" ]] && { log "INFO" "Cron job setup cancelled."; return 0; }
            schedule="${custom_schedule}"
            description="custom schedule: ${schedule}"
            ;;
        5)
            if [[ "${DRY_RUN}" == true ]]; then
                log "INFO" "DRY-RUN: Would remove cron job for ${script_basename}"
            else
                local temp_crontab=$(mktemp) || { log "ERROR" "Failed to create temporary file."; return 1; }
                crontab -l > "${temp_crontab}.orig" 2>/dev/null || touch "${temp_crontab}"
                # Remove lines containing either the script basename or full path (use -F for fixed string matching)
                grep -vF "${script_basename}" "${temp_crontab}.orig" | grep -vF "${script_path}" > "${temp_crontab}" || true
                diff "${temp_crontab}.orig" "${temp_crontab}" >/dev/null && log "INFO" "No matching cron jobs found to remove" || { crontab "${temp_crontab}" && log "SUCCESS" "Removed cron job(s) for ${script_basename}" || { log "ERROR" "Failed to update crontab"; rm -f "${temp_crontab}" "${temp_crontab}.orig" 2>/dev/null || true; return 1; }; }
                rm -f "${temp_crontab}" "${temp_crontab}.orig" 2>/dev/null || true
            fi
            return 0
            ;;
        6) log "INFO" "Cron job setup cancelled."; return 0 ;;
        *) log "ERROR" "Invalid choice."; return 1 ;;
    esac
    
    printf "\n${YELLOW}This will setup a cron job to run %s.${NC}\n" "${description}"
    printf "${YELLOW}Cron schedule: %s${NC}\n" "${schedule}"
    printf "${YELLOW}Command: %s --cron backup${NC}\n\n" "${script_path}"
    printf "Do you want to proceed? (y/n/c): "
    local confirm
    read -r confirm
    [[ "${confirm,,}" == "c" || "${confirm,,}" != "y" ]] && { log "INFO" "Cron job setup cancelled."; return 0; }
    
    if [[ "${DRY_RUN}" == true ]]; then
        log "INFO" "DRY-RUN: Would add cron job: ${schedule} ${script_path} --cron backup"
        return 0
    fi
    
    local temp_crontab=$(mktemp) || { log "ERROR" "Failed to create temporary file."; return 1; }
    crontab -l > "${temp_crontab}" 2>/dev/null || touch "${temp_crontab}"
    # Remove any existing cron jobs for this script (by basename or full path, use -F for fixed string matching)
    grep -vF "${script_basename}" "${temp_crontab}" | grep -vF "${script_path}" > "${temp_crontab}.new" || true
    mv "${temp_crontab}.new" "${temp_crontab}"
    printf "%s %s --cron backup\n" "${schedule}" "${script_path}" >> "${temp_crontab}"
    crontab "${temp_crontab}" && log "SUCCESS" "Cron job setup successfully for ${description}." || { log "ERROR" "Failed to setup cron job."; rm -f "${temp_crontab}" 2>/dev/null || true; return 1; }
    rm -f "${temp_crontab}" 2>/dev/null || true
    return 0
}