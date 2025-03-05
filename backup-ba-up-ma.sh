#!/usr/bin/env bash

# Backup management for Pangolin stack

# Validate backup directory
validate_backup_dir() {
    if [[ ! -d "${BACKUP_DIR}" ]]; then
        if [[ "${DRY_RUN}" == true ]]; then
            log "INFO" "DRY-RUN: Would create backup directory: ${BACKUP_DIR}"
        else
            mkdir -p "${BACKUP_DIR}" || { log "ERROR" "Failed to create backup directory: ${BACKUP_DIR}"; return 1; }
            log "INFO" "Created backup directory: ${BACKUP_DIR}"
        fi
    fi
    [[ ! -w "${BACKUP_DIR}" && "${DRY_RUN}" == false ]] && { log "ERROR" "Backup directory is not writable: ${BACKUP_DIR}"; return 1; }
    return 0
}

# Create backup
create_backup() {
    local backup_name="pangolin_backup_${BACKUP_TIMESTAMP}"
    local backup_path="${BACKUP_DIR}/${backup_name}"
    local archive_path="${backup_path}.tar.gz"
    
    log "INFO" "Starting backup process..."
    
    validate_backup_dir || return 1
    check_docker || return 1
    check_stack || log "WARNING" "Stack check failed, but continuing with backup."
    
    if [[ "${DRY_RUN}" == true ]]; then
        log "INFO" "DRY-RUN: Would create backup in ${backup_path}"
        for item in "${BACKUP_ITEMS[@]}"; do
            local source_path="${PANGOLIN_DIR}/${item}"
            [[ -e "${source_path}" ]] && log "INFO" "DRY-RUN:   - ${item}" || log "WARNING" "DRY-RUN:   - ${item} (does not exist)"
        done
        log "SUCCESS" "DRY-RUN: Backup simulation completed successfully"
        return 0
    fi
    
    local temp_backup_path=$(mktemp -d) || { log "ERROR" "Failed to create temporary backup directory"; return 1; }
    temp_dir="${temp_backup_path}"
    
    for item in "${BACKUP_ITEMS[@]}"; do
        local source_path="${PANGOLIN_DIR}/${item}"
        if [[ ! -e "${source_path}" ]]; then
            log "WARNING" "Source path does not exist: ${source_path}"
            continue
        fi
        mkdir -p "${temp_backup_path}/$(dirname "${item}")" || return 1
        cp -a "${source_path}" "${temp_backup_path}/${item}" || return 1
        log "INFO" "Copied: ${item}"
    done
    
    {
        printf "Backup created: %s\n" "$(date)"
        printf "Pangolin directory: %s\n" "${PANGOLIN_DIR}"
        printf "Items included:\n"
        for item in "${BACKUP_ITEMS[@]}"; do
            printf "  %s\n" "${item}"
        done
    } > "${temp_backup_path}/BACKUP_INFO.txt" || return 1
    
    tar -czf "${archive_path}" -C "$(dirname "${temp_backup_path}")" "$(basename "${temp_backup_path}")" || { log "ERROR" "Failed to create archive: ${archive_path}"; return 1; }
    
    rm -rf "${temp_backup_path}" 2>/dev/null || true
    local archive_size=$(du -h "${archive_path}" 2>/dev/null | cut -f1) || archive_size="unknown size"
    log "SUCCESS" "Backup created successfully: ${archive_path} (${archive_size})"
    
    cleanup_old_backups
    return 0
}

# Cleanup old backups
cleanup_old_backups() {
    log "INFO" "Checking for old backups to remove..."
    
    if [[ "${DRY_RUN}" == true ]]; then
        log "INFO" "DRY-RUN: Would remove backups older than ${RETENTION_DAYS} days"
        return 0
    fi
    
    local cutoff_date
    if [[ "$(uname)" == "Darwin" ]]; then
        cutoff_date=$(date -v-"${RETENTION_DAYS}"d +%Y%m%d)
    else
        cutoff_date=$(date -d "${RETENTION_DAYS} days ago" +%Y%m%d)
    fi
    
    local count=0
    shopt -s nullglob
    local backup_files=("${BACKUP_DIR}"/pangolin_backup_*.tar.gz)
    shopt -u nullglob
    
    for backup in "${backup_files[@]}"; do
        [[ ! -f "${backup}" ]] && continue
        local backup_date=$(basename "${backup}" | grep -oE 'pangolin_backup_[0-9]{8}' | cut -d'_' -f3 || echo "")
        if [[ -n "${backup_date}" && "${backup_date}" -lt "${cutoff_date}" ]]; then
            log "INFO" "Removing old backup: $(basename "${backup}")"
            rm -f "${backup}" && ((count++)) || log "WARNING" "Failed to remove backup: ${backup}"
        fi
    done
    
    [[ ${count} -eq 0 ]] && log "INFO" "No old backups to remove." || log "SUCCESS" "Removed ${count} old backup(s)."
}

# List available backups
list_backups() {
    print_header "Available Backups"
    
    shopt -s nullglob
    local backup_files=("${BACKUP_DIR}"/pangolin_backup_*.tar.gz)
    shopt -u nullglob
    
    if [[ ${#backup_files[@]} -eq 0 ]]; then
        printf "No backups found in %s\n" "${BACKUP_DIR}"
        BACKUPS_ARRAY=()
        return 0
    fi
    
    readarray -t backups < <(printf '%s\n' "${backup_files[@]}" | sort -r)
    BACKUPS_ARRAY=("${backups[@]}")
    
    printf "${CYAN}Found %d backup(s):${NC}\n\n" "${#backups[@]}"
    for i in "${!backups[@]}"; do
        local backup="${backups[$i]}"
        local filename=$(basename "${backup}")
        local size=$(du -h "${backup}" 2>/dev/null | cut -f1 || echo "unknown size")
        local date_part=$(echo "${filename}" | grep -oE 'pangolin_backup_[0-9]{8}_[0-9]{6}' | cut -d'_' -f2,3 || echo "")
        local formatted_date="Unknown date"
        if [[ -n "${date_part}" ]]; then
            local year="${date_part:0:4}"
            local month="${date_part:4:2}"
            local day="${date_part:6:2}"
            local hour="${date_part:9:2}"
            local minute="${date_part:11:2}"
            local second="${date_part:13:2}"
            formatted_date="${year}-${month}-${day} ${hour}:${minute}:${second}"
        fi
        printf "${YELLOW}[%d]${NC} %s (%s) - %s\n" "${i}" "${filename}" "${size}" "${formatted_date}"
    done
    printf "\n"
    return 0
}

# Delete specific backups
delete_backups() {
    print_header "Delete Backups"
    
    list_backups
    if [[ ${#BACKUPS_ARRAY[@]} -eq 0 ]]; then
        log "ERROR" "No backups available for deletion."
        [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }
        return 0
    fi
    
    printf "${YELLOW}Enter the index of the backup to delete, multiple indexes separated by spaces, 'a' for all, or 'c' to cancel:${NC}\n"
    local selection
    read -r selection
    
    if [[ "${selection,,}" == "c" ]]; then
        log "INFO" "Deletion cancelled by user."
        return 0
    fi
    
    if [[ "${selection,,}" == "a" ]]; then
        printf "${YELLOW}Are you ABSOLUTELY SURE you want to delete ALL backups? (Type 'YES' to confirm):${NC}\n"
        local confirmation
        read -r confirmation
        [[ "${confirmation^^}" != "YES" ]] && { log "INFO" "Deletion cancelled by user."; return 0; }
        
        if [[ "${DRY_RUN}" == true ]]; then
            log "INFO" "DRY-RUN: Would delete all ${#BACKUPS_ARRAY[@]} backups"
            return 0
        fi
        
        local deleted_count=0
        for backup in "${BACKUPS_ARRAY[@]}"; do
            log "INFO" "Deleting backup: $(basename "${backup}")"
            rm -f "${backup}" && ((deleted_count++)) || log "WARNING" "Failed to delete backup: ${backup}"
        done
        log "SUCCESS" "Deleted ${deleted_count} of ${#BACKUPS_ARRAY[@]} backups"
        return 0
    fi
    
    local indexes=()
    read -ra indexes <<< "${selection}"
    for index in "${indexes[@]}"; do
        if ! [[ "${index}" =~ ^[0-9]+$ ]] || [[ "${index}" -ge "${#BACKUPS_ARRAY[@]}" ]]; then
            log "ERROR" "Invalid selection: ${index}"
            [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }
            return 0
        fi
    done
    
    if [[ ${#indexes[@]} -eq 1 ]]; then
        local backup_to_delete="${BACKUPS_ARRAY[${indexes[0]}]}"
        printf "${YELLOW}Are you sure you want to delete: %s? (y/n):${NC}\n" "$(basename "${backup_to_delete}")"
    else
        printf "${YELLOW}Are you sure you want to delete %d selected backups? (y/n):${NC}\n" "${#indexes[@]}"
    fi
    local confirm
    read -r confirm
    [[ "${confirm,,}" != "y" ]] && { log "INFO" "Deletion cancelled by user."; return 0; }
    
    if [[ "${DRY_RUN}" == true ]]; then
        for index in "${indexes[@]}"; do
            log "INFO" "DRY-RUN: Would delete backup: $(basename "${BACKUPS_ARRAY[${index}]}")"
        done
        return 0
    fi
    
    local deleted_count=0
    for index in "${indexes[@]}"; do
        local backup_to_delete="${BACKUPS_ARRAY[${index}]}"
        log "INFO" "Deleting backup: $(basename "${backup_to_delete}")"
        rm -f "${backup_to_delete}" && { ((deleted_count++)); log "SUCCESS" "Deleted backup: $(basename "${backup_to_delete}")"; } || log "ERROR" "Failed to delete backup: $(basename "${backup_to_delete}")"
    done
    log "INFO" "Deleted ${deleted_count} of ${#indexes[@]} selected backups"
    return 0
}

# Validate backup contents
validate_backup() {
    local backup_dir="$1"
    [[ ! -d "${backup_dir}" || ! -r "${backup_dir}" ]] && { log "ERROR" "Invalid or unreadable backup directory: ${backup_dir}"; return 1; }
    [[ ! -f "${backup_dir}/docker-compose.yml" || ! -r "${backup_dir}/docker-compose.yml" ]] && { log "ERROR" "Missing or unreadable docker-compose.yml"; return 1; }
    [[ ! -d "${backup_dir}/config" || ! -r "${backup_dir}/config" ]] && { log "ERROR" "Missing or unreadable config backup"; return 1; }
    return 0
}

# Find latest backup
find_latest_backup() {
    shopt -s nullglob
    local backup_files=("${BACKUP_DIR}"/pangolin_backup_*.tar.gz)
    shopt -u nullglob
    [[ ${#backup_files[@]} -eq 0 ]] && { log "ERROR" "No valid backup found in ${BACKUP_DIR}"; return 1; }
    local latest_backup=$(printf '%s\n' "${backup_files[@]}" | sort -r | head -n1)
    printf "%s" "${latest_backup}"
}

# Restore from backup
restore_backup() {
    print_header "Restore from Backup"
    
    local selected_backup=""
    if [[ -n "${1:-}" ]]; then
        selected_backup="$1"
        [[ ! -f "${selected_backup}" ]] && { log "ERROR" "Specified backup file does not exist: ${selected_backup}"; [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }; return 0; }
        log "INFO" "Using specified backup: ${selected_backup}"
    else
        list_backups
        [[ ${#BACKUPS_ARRAY[@]} -eq 0 ]] && { log "ERROR" "No backups available for restore."; [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }; return 0; }
        
        printf "${YELLOW}Enter the index of the backup to restore, 'l' for latest, or 'c' to cancel:${NC}\n"
        local selection
        read -r selection
        
        if [[ "${selection,,}" == "c" ]]; then
            log "INFO" "Restore cancelled by user."
            return 0
        elif [[ "${selection,,}" == "l" ]]; then
            selected_backup=$(find_latest_backup) || { [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }; return 0; }
            log "INFO" "Using latest backup: $(basename "${selected_backup}")"
        else
            if ! [[ "${selection}" =~ ^[0-9]+$ ]] || [[ "${selection}" -ge "${#BACKUPS_ARRAY[@]}" ]]; then
                log "ERROR" "Invalid selection: ${selection}"
                [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }
                return 0
            fi
            selected_backup="${BACKUPS_ARRAY[$selection]}"
        fi
    fi
    
    local backup_filename=$(basename "${selected_backup}")
    printf "\n"
    print_warning "You are about to restore from backup: ${backup_filename}"
    print_warning "This will OVERWRITE your current Pangolin configuration!"
    print_warning "Make sure the Pangolin stack is not running before proceeding."
    printf "\n"
    printf "${YELLOW}Are you ABSOLUTELY SURE you want to proceed? (Type 'YES' to confirm):${NC}\n"
    local confirmation
    read -r confirmation
    [[ "${confirmation^^}" != "YES" ]] && { log "INFO" "Restore cancelled by user."; return 0; }
    
    if [[ "${DRY_RUN}" == true ]]; then
        log "INFO" "DRY-RUN: Would restore from backup: ${backup_filename}"
        log "SUCCESS" "DRY-RUN: Restore simulation completed successfully"
        return 0
    fi
    
    if docker_compose ps 2>/dev/null | grep -q "Up"; then
        log "WARNING" "Pangolin stack appears to be running."
        printf "${YELLOW}Do you want to stop the stack before restoring? (y/n/c):${NC}\n"
        local stop_stack
        read -r stop_stack
        if [[ "${stop_stack,,}" == "c" ]]; then
            log "INFO" "Restore cancelled by user."
            return 0
        elif [[ "${stop_stack,,}" == "y" ]]; then
            log "INFO" "Stopping Pangolin stack..."
            graceful_shutdown || { log "ERROR" "Failed to stop the stack."; [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }; return 0; }
        else
            log "WARNING" "Proceeding with restore while stack is running."
        fi
    fi
    
    local temp_dir=$(mktemp -d) || { log "ERROR" "Failed to create temporary directory."; [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }; return 0; }
    log "INFO" "Extracting backup..."
    tar -xzf "${selected_backup}" -C "${temp_dir}" || { log "ERROR" "Failed to extract backup archive."; rm -rf "${temp_dir}" 2>/dev/null || true; [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }; return 0; }
    
    local extracted_dir=$(find "${temp_dir}" -mindepth 1 -maxdepth 1 -type d | head -1)
    [[ -z "${extracted_dir}" ]] && { log "ERROR" "Failed to find extracted directory."; rm -rf "${temp_dir}" 2>/dev/null || true; [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }; return 0; }
    
    local current_backup_dir="${BACKUP_DIR}/pre_restore_${BACKUP_TIMESTAMP}"
    mkdir -p "${current_backup_dir}" || { log "ERROR" "Failed to create directory for current configuration backup."; rm -rf "${temp_dir}" 2>/dev/null || true; [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }; return 0; }
    
    log "INFO" "Creating backup of current configuration before restore..."
    for item in "${BACKUP_ITEMS[@]}"; do
        local source_path="${PANGOLIN_DIR}/${item}"
        if [[ -e "${source_path}" ]]; then
            mkdir -p "${current_backup_dir}/$(dirname "${item}")" || continue
            cp -a "${source_path}" "${current_backup_dir}/$(dirname "${item}")/" && log "INFO" "Backed up current: ${item}" || log "WARNING" "Failed to backup current: ${item}"
        fi
    done
    
    tar -czf "${current_backup_dir}.tar.gz" -C "${BACKUP_DIR}" "pre_restore_${BACKUP_TIMESTAMP}" || { log "ERROR" "Failed to create archive of current configuration."; rm -rf "${current_backup_dir}" "${temp_dir}" 2>/dev/null || true; [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }; return 0; }
    rm -rf "${current_backup_dir}" 2>/dev/null || true
    log "SUCCESS" "Created backup of current configuration: ${current_backup_dir}.tar.gz"
    
    log "INFO" "Restoring files from backup..."
    while IFS= read -r item_path; do
        local item=$(basename "${item_path}")
        [[ "${item}" == "BACKUP_INFO.txt" ]] && continue
        local source_path="${extracted_dir}/${item}"
        local dest_path="${PANGOLIN_DIR}/${item}"
        
        if [[ -e "${dest_path}" ]]; then
            log "INFO" "Removing existing: ${dest_path}"
            rm -rf "${dest_path}" || { log "ERROR" "Failed to remove existing item: ${dest_path}"; log "INFO" "Restore incomplete. Use: ${current_backup_dir}.tar.gz"; rm -rf "${temp_dir}" 2>/dev/null || true; [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }; return 0; }
        fi
        
        mkdir -p "$(dirname "${dest_path}")" || { log "ERROR" "Failed to create directory structure for: ${item}"; log "INFO" "Restore incomplete. Use: ${current_backup_dir}.tar.gz"; rm -rf "${temp_dir}" 2>/dev/null || true; [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }; return 0; }
        cp -a "${source_path}" "${dest_path}" || { log "ERROR" "Failed to restore item: ${item}"; log "INFO" "Restore incomplete. Use: ${current_backup_dir}.tar.gz"; rm -rf "${temp_dir}" 2>/dev/null || true; [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }; return 0; }
        log "INFO" "Restored: ${item}"
    done < <(find "${extracted_dir}" -mindepth 1 -maxdepth 1 -not -name "BACKUP_INFO.txt")
    
    rm -rf "${temp_dir}" 2>/dev/null || true
    log "SUCCESS" "Restore completed successfully."
    
    printf "${YELLOW}Do you want to start the Pangolin stack now? (y/n):${NC}\n"
    local start_stack
    read -r start_stack
    if [[ "${start_stack,,}" == "y" ]]; then
        log "INFO" "Starting Pangolin stack..."
        docker_compose up -d || { log "ERROR" "Failed to start Pangolin stack."; [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }; return 0; }
        log "SUCCESS" "Pangolin stack started successfully."
    else
        log "INFO" "Pangolin stack not started."
    fi
    return 0
}