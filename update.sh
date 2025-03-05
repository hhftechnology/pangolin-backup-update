#!/usr/bin/env bash

# Update management for Pangolin stack

# Graceful service shutdown
graceful_shutdown() {
    log "INFO" "Starting graceful shutdown of services..."
    docker_compose stop -t 30 || log "WARNING" "Graceful stop failed, forcing shutdown..."
    docker_compose down --timeout 30 || { log "ERROR" "Failed to shut down services"; return 1; }
    docker_compose ps | grep -q "Up" && { log "ERROR" "Some services still running after shutdown"; return 1; }
    log "INFO" "Services stopped successfully"
    return 0
}

# Extract current image tags
extract_tag() {
    local image_pattern=$1
    local tag=""
    grep -q -E "image:\\s*${image_pattern}:" "${DOCKER_COMPOSE_FILE}" || { log "WARNING" "Image pattern '${image_pattern}' not found in docker-compose.yml"; printf "%s" "latest"; return 0; }
    tag=$(grep -E "image:\\s*${image_pattern}:" "${DOCKER_COMPOSE_FILE}" | head -n1 | sed -E 's/.*image:\s*[^:]+:([^"'\''\\s]+).*/\1/' || echo "latest")
    [[ -z "${tag}" ]] && { log "WARNING" "Could not extract tag for '${image_pattern}', using 'latest'"; tag="latest"; }
    printf "%s" "${tag}"
    return 0
}

# Get running CrowdSec version
get_running_crowdsec_version() {
    local version=$(docker_compose exec -T crowdsec crowdsec -version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' || echo "Unknown")
    printf "%s" "${version}"
}

# Get current tags
get_current_tags() {
    log "INFO" "Reading current image tags..."
    
    if [[ ! -f "${DOCKER_COMPOSE_FILE}" ]]; then
        log "ERROR" "Docker compose file not found: ${DOCKER_COMPOSE_FILE}"
        if [[ "${INTERACTIVE}" == true ]]; then
            printf "\n${YELLOW}Would you like to specify a different docker-compose file? (y/n/c):${NC} "
            local response
            read -r response
            if [[ "${response,,}" == "c" ]]; then
                log "INFO" "Operation cancelled by user."
                return 1
            elif [[ "${response,,}" == "y" ]]; then
                printf "Enter the path to your docker-compose.yml file: "
                read -r DOCKER_COMPOSE_FILE
                return "${FUNCNAME[0]}"
            fi
        fi
        PANGOLIN_CURRENT="latest"
        GERBIL_CURRENT="latest"
        TRAEFIK_CURRENT="latest"
        [[ "${INCLUDE_CROWDSEC}" == true ]] && CROWDSEC_CURRENT="latest"
        return 0
    fi
    
    PANGOLIN_CURRENT=$(extract_tag "fosrl/pangolin")
    log "INFO" "Found Pangolin tag: ${PANGOLIN_CURRENT}"
    GERBIL_CURRENT=$(extract_tag "fosrl/gerbil")
    log "INFO" "Found Gerbil tag: ${GERBIL_CURRENT}"
    TRAEFIK_CURRENT=$(extract_tag "traefik")
    log "INFO" "Found Traefik tag: ${TRAEFIK_CURRENT}"
    
    if [[ "${INCLUDE_CROWDSEC}" == true ]]; then
        CROWDSEC_CURRENT=$(extract_tag "crowdsecurity/crowdsec")
        CROWDSEC_RUNNING=$(get_running_crowdsec_version)
        log "INFO" "Found CrowdSec tag: ${CROWDSEC_CURRENT}, Running version: ${CROWDSEC_RUNNING}"
    fi
    return 0
}

# Interactive tag selection
get_new_tags() {
    log "INFO" "Requesting new image tags from user..."
    
    printf "\n${CYAN}Current versions:${NC}\n"
    printf "${CYAN}------------------------${NC}\n"
    printf "${CYAN}Pangolin tag:${NC} ${YELLOW}%s${NC}\n" "${PANGOLIN_CURRENT}"
    printf "Enter new Pangolin tag (or press enter to keep current, 'c' to cancel): "
    local new_tag
    read -r new_tag
    [[ "${new_tag,,}" == "c" ]] && { log "INFO" "Update cancelled by user."; OPERATION_CANCELLED=true; return 0; }
    PANGOLIN_NEW=${new_tag:-${PANGOLIN_CURRENT}}
    
    printf "${CYAN}Gerbil tag:${NC} ${YELLOW}%s${NC}\n" "${GERBIL_CURRENT}"
    printf "Enter new Gerbil tag (or press enter to keep current, 'c' to cancel): "
    read -r new_tag
    [[ "${new_tag,,}" == "c" ]] && { log "INFO" "Update cancelled by user."; OPERATION_CANCELLED=true; return 0; }
    GERBIL_NEW=${new_tag:-${GERBIL_CURRENT}}
    
    printf "${CYAN}Traefik tag:${NC} ${YELLOW}%s${NC}\n" "${TRAEFIK_CURRENT}"
    printf "Enter new Traefik tag (or press enter to keep current, 'c' to cancel): "
    read -r new_tag
    [[ "${new_tag,,}" == "c" ]] && { log "INFO" "Update cancelled by user."; OPERATION_CANCELLED=true; return 0; }
    TRAEFIK_NEW=${new_tag:-${TRAEFIK_CURRENT}}
    
    if [[ "${INCLUDE_CROWDSEC}" == true ]]; then
        printf "${CYAN}CrowdSec tag:${NC} ${YELLOW}%s${NC}, ${CYAN}Running version:${NC} ${YELLOW}%s${NC}\n" "${CROWDSEC_CURRENT}" "${CROWDSEC_RUNNING}"
        printf "Enter new CrowdSec tag (or press enter to keep current, 'c' to cancel): "
        read -r new_tag
        [[ "${new_tag,,}" == "c" ]] && { log "INFO" "Update cancelled by user."; OPERATION_CANCELLED=true; return 0; }
        CROWDSEC_NEW=${new_tag:-${CROWDSEC_CURRENT}}
    fi
    
    printf "\n${CYAN}Summary of changes:${NC}\n"
    printf "${CYAN}------------------------${NC}\n"
    printf "Pangolin: ${YELLOW}%s${NC} -> ${GREEN}%s${NC}\n" "${PANGOLIN_CURRENT}" "${PANGOLIN_NEW}"
    printf "Gerbil: ${YELLOW}%s${NC} -> ${GREEN}%s${NC}\n" "${GERBIL_CURRENT}" "${GERBIL_NEW}"
    printf "Traefik: ${YELLOW}%s${NC} -> ${GREEN}%s${NC}\n" "${TRAEFIK_CURRENT}" "${TRAEFIK_NEW}"
    [[ "${INCLUDE_CROWDSEC}" == true ]] && printf "CrowdSec: ${YELLOW}%s${NC} -> ${GREEN}%s${NC}\n" "${CROWDSEC_CURRENT}" "${CROWDSEC_NEW}"
    printf "${CYAN}------------------------${NC}\n"
    
    printf "Proceed with these changes? (y/N/c): "
    local confirm
    read -r confirm
    if [[ "${confirm,,}" == "c" || ! "${confirm,,}" =~ ^y$ ]]; then
        log "INFO" "Update cancelled by user"
        OPERATION_CANCELLED=true
        return 0
    fi
    return 0
}

# Create backup for update
create_update_backup() {
    local update_backup_dir="${BACKUP_DIR}/update_${BACKUP_TIMESTAMP}"
    local archive_path="${update_backup_dir}.tar.gz"
    
    log "INFO" "Creating backup before update..."
    mkdir -p "${update_backup_dir}" || { log "ERROR" "Failed to create update backup directory: ${update_backup_dir}"; return 1; }
    grep "image:" "${DOCKER_COMPOSE_FILE}" > "${update_backup_dir}/old_tags.txt" || log "WARNING" "Failed to save current image tags, but continuing"
    [[ -d "./config" ]] && cp -r "./config" "${update_backup_dir}/" || log "WARNING" "Failed to backup config directory, but continuing"
    cp "${DOCKER_COMPOSE_FILE}" "${update_backup_dir}/" || { log "ERROR" "Failed to backup docker-compose.yml"; rm -rf "${update_backup_dir}" 2>/dev/null || true; return 1; }
    
    tar -czf "${archive_path}" -C "${BACKUP_DIR}" "update_${BACKUP_TIMESTAMP}" || { log "ERROR" "Failed to create backup archive: ${archive_path}"; rm -rf "${update_backup_dir}" 2>/dev/null || true; return 1; }
    rm -rf "${update_backup_dir}" 2>/dev/null || true
    log "SUCCESS" "Update backup created successfully: ${archive_path}"
    return 0
}

# Update service images
update_images() {
    log "INFO" "Starting update process..."
    
    if [[ "${DRY_RUN}" == true ]]; then
        log "INFO" "DRY-RUN: Would update image tags in docker-compose.yml"
        log "SUCCESS" "DRY-RUN: Update simulation completed successfully"
        return 0
    fi
    
    if [[ ! -f "${DOCKER_COMPOSE_FILE}" || ! -w "${DOCKER_COMPOSE_FILE}" ]]; then
        log "ERROR" "Docker compose file not found or not writable: ${DOCKER_COMPOSE_FILE}"
        if [[ "${INTERACTIVE}" == true ]]; then
            printf "${YELLOW}Enter the path to your docker-compose.yml file (or 'c' to cancel):${NC} "
            local response
            read -r response
            [[ "${response,,}" == "c" ]] && { log "INFO" "Update cancelled by user."; return 1; }
            DOCKER_COMPOSE_FILE="${response}"
            [[ ! -f "${DOCKER_COMPOSE_FILE}" || ! -w "${DOCKER_COMPOSE_FILE}" ]] && { log "ERROR" "Invalid file: ${DOCKER_COMPOSE_FILE}"; return 1; }
        else
            return 1
        fi
    fi
    
    local max_attempts=3
    local attempt=1
    local shutdown_success=false
    while [[ ${attempt} -le ${max_attempts} && "${shutdown_success}" == false ]]; do
        graceful_shutdown && shutdown_success=true || { log "WARNING" "Shutdown attempt ${attempt}/${max_attempts} failed. Retrying..."; sleep 5; ((attempt++)); }
    done
    [[ "${shutdown_success}" == false ]] && { log "ERROR" "Failed to shutdown services after ${max_attempts} attempts."; return 1; }
    
    local tmp_file=$(mktemp) || { log "ERROR" "Failed to create temporary file."; return 1; }
    temp_dir="${tmp_file}"
    cp "${DOCKER_COMPOSE_FILE}" "${tmp_file}" || { log "ERROR" "Failed to create backup of docker-compose.yml"; return 1; }
    
    safe_replace() {
        local pattern="$1"
        local replacement="$2"
        local file="$3"
        if ! grep -q "${pattern}" "${file}"; then
            log "WARNING" "Pattern not found: ${pattern}"
            return 1
        fi
        sed -i "s|${pattern}|${replacement}|g" "${file}" || { log "ERROR" "Failed to update image tag: ${pattern} -> ${replacement}"; return 1; }
        log "SUCCESS" "Updated: ${pattern} -> ${replacement}"
        return 0
    }
    
    local update_successful=true
    [[ -n "${PANGOLIN_NEW}" ]] && safe_replace "image: fosrl/pangolin:${PANGOLIN_CURRENT}" "image: fosrl/pangolin:${PANGOLIN_NEW}" "${tmp_file}" || update_successful=false
    [[ -n "${GERBIL_NEW}" ]] && safe_replace "image: fosrl/gerbil:${GERBIL_CURRENT}" "image: fosrl/gerbil:${GERBIL_NEW}" "${tmp_file}" || update_successful=false
    [[ -n "${TRAEFIK_NEW}" ]] && safe_replace "image: traefik:${TRAEFIK_CURRENT}" "image: traefik:${TRAEFIK_NEW}" "${tmp_file}" || update_successful=false
    [[ "${INCLUDE_CROWDSEC}" == true && -n "${CROWDSEC_NEW}" ]] && safe_replace "image: crowdsecurity/crowdsec:${CROWDSEC_CURRENT}" "image: crowdsecurity/crowdsec:${CROWDSEC_NEW}" "${tmp_file}" || update_successful=false
    
    [[ "${update_successful}" == false && "${INTERACTIVE}" == true ]] && {
        printf "${YELLOW}Some updates failed. Continue anyway? (y/n/c):${NC} "
        local response
        read -r response
        [[ "${response,,}" == "c" || "${response,,}" != "y" ]] && { log "INFO" "Update cancelled by user"; return 1; }
    }
    
    mv "${tmp_file}" "${DOCKER_COMPOSE_FILE}" || { log "ERROR" "Failed to update docker-compose.yml"; return 1; }
    
    log "INFO" "Pulling new images..."
    docker_compose pull || {
        log "WARNING" "Failed to pull some images"
        if [[ "${INTERACTIVE}" == true ]]; then
            printf "${YELLOW}Some images failed to pull. Continue anyway? (y/n/c):${NC} "
            local response
            read -r response
            [[ "${response,,}" == "c" || "${response,,}" != "y" ]] && { log "INFO" "Update cancelled by user"; return 1; }
        else
            return 1
        fi
    }
    
    log "INFO" "Starting updated stack..."
    docker_compose up -d || { log "ERROR" "Failed to start updated stack"; return 1; }
    
    log "INFO" "Waiting for services to start..."
    local max_attempts=12
    local attempt=1
    local all_up=false
    while [[ ${attempt} -le ${max_attempts} && "${all_up}" == false ]]; do
        printf "Checking service status (attempt %d/%d)...\n" "${attempt}" "${max_attempts}"
        sleep 5
        verify_services && all_up=true || ((attempt++))
    done
    
    if [[ "${all_up}" == true ]]; then
        log "SUCCESS" "Services have been updated successfully"
        docker_compose ps
        return 0
    else
        log "WARNING" "Not all services are running after update"
        docker_compose ps
        return 1
    fi
}

# Update with CrowdSec
update_with_crowdsec() {
    print_header "UPDATE PANGOLIN STACK (WITH CROWDSEC)"
    INCLUDE_CROWDSEC=true
    SERVICES=("${SERVICES_WITH_CROWDSEC[@]}")
    OPERATION_CANCELLED=false
    
    create_update_backup || return 0
    get_current_tags || return 0
    get_new_tags
    [[ "${OPERATION_CANCELLED}" == true ]] && { [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }; return 0; }
    update_images || return 0
    log "SUCCESS" "Pangolin stack (with CrowdSec) has been updated successfully"
    return 0
}

# Update without CrowdSec
update_without_crowdsec() {
    print_header "UPDATE PANGOLIN STACK (WITHOUT CROWDSEC)"
    INCLUDE_CROWDSEC=false
    SERVICES=("${SERVICES_BASIC[@]}")
    OPERATION_CANCELLED=false
    
    create_update_backup || return 0
    get_current_tags || return 0
    get_new_tags
    [[ "${OPERATION_CANCELLED}" == true ]] && { [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }; return 0; }
    update_images || return 0
    log "SUCCESS" "Pangolin stack (without CrowdSec) has been updated successfully"
    return 0
}