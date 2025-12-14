#!/usr/bin/env bash

# Update management for Pangolin stack
# Improved for stable releases with better compatibility and error handling

# Graceful service shutdown
graceful_shutdown() {
    log "INFO" "Starting graceful shutdown of services..."
    docker_compose stop -t 30 || log "WARNING" "Graceful stop failed, forcing shutdown..."
    docker_compose down --timeout 30 || { log "ERROR" "Failed to shut down services"; return 1; }
    docker_compose ps | grep -q "Up" && { log "ERROR" "Some services still running after shutdown"; return 1; }
    log "INFO" "Services stopped successfully"
    return 0
}

# Execute docker compose commands with proper wrapping
docker_compose() {
    if docker compose version &>/dev/null; then
        docker compose -f "${DOCKER_COMPOSE_FILE}" "$@"
    elif command -v docker-compose &>/dev/null; then
        docker-compose -f "${DOCKER_COMPOSE_FILE}" "$@"
    else
        log "ERROR" "Neither 'docker compose' nor 'docker-compose' is available"
        return 1
    fi
}

# Extract current image tags with robust pattern matching
# Handles any registry prefix (docker.io/, ghcr.io/, custom registries, or no registry)
extract_tag() {
    local service_name=$1
    local image_name=$2
    local tag=""
    local in_service=false
    local service_pattern="^[[:space:]]*${service_name}:"
    
    # Extract the base image name (the part we need to match)
    # The image_name parameter is the base we're looking for (e.g., "fosrl/pangolin" or "traefik")
    # We want to match it with any registry prefix or none:
    # - "fosrl/pangolin" matches: "fosrl/pangolin:tag", "docker.io/fosrl/pangolin:tag", "ghcr.io/fosrl/pangolin:tag"
    # - "traefik" matches: "traefik:tag", "docker.io/traefik:tag", "registry/traefik:tag"
    local image_base="${image_name}"
    
    # Escape special regex characters in image_base for pattern matching
    local escaped_base=$(printf '%s\n' "${image_base}" | sed 's/[[\.*^$()+?{|]/\\&/g')
    
    # Strategy 1: Try using docker compose config (most reliable)
    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1 2>/dev/null; then
        local compose_config=$(docker compose -f "${DOCKER_COMPOSE_FILE}" config 2>/dev/null)
        if [[ -n "${compose_config}" ]]; then
            # Find the service section and extract image line
            local in_section=false
            while IFS= read -r line || [[ -n "${line}" ]]; do
                # Check if we're entering the service section
                if [[ "${line}" =~ ^[[:space:]]*${service_name}:[[:space:]]*$ ]]; then
                    in_section=true
                    continue
                fi
                
                # Check if we've left the service section
                if [[ "${in_section}" == true ]]; then
                    # If we hit another top-level service, we've left
                    if [[ "${line}" =~ ^[[:space:]]*[a-zA-Z][a-zA-Z0-9_-]*:[[:space:]]*$ ]]; then
                        local indent=$(echo "${line}" | sed 's/[^ ].*//' | wc -c)
                        if [[ ${indent} -le 2 ]]; then
                            break
                        fi
                    fi
                    
                    # Look for image line
                    if [[ "${line}" =~ image:[[:space:]]* ]]; then
                        local image_value=$(echo "${line}" | sed 's/^[[:space:]]*image:[[:space:]]*//' | sed 's/[[:space:]]*$//')
                        # Remove quotes
                        image_value="${image_value//\"/}"
                        image_value="${image_value//\'/}"
                        
                        # Check if this image ends with our image_base (handles any registry prefix)
                        # Match pattern: anything ending with /image_base:tag or /image_base
                        if [[ "${image_value}" =~ /${escaped_base}: ]] || [[ "${image_value}" =~ /${escaped_base}$ ]] || \
                           [[ "${image_value}" =~ ^${escaped_base}: ]] || [[ "${image_value}" == "${escaped_base}" ]]; then
                            # Extract tag (everything after the last colon)
                            if [[ "${image_value}" =~ :([^:]+)$ ]]; then
                                tag="${BASH_REMATCH[1]}"
                                break
                            else
                                # No tag specified, default to latest
                                tag="latest"
                                break
                            fi
                        fi
                    fi
                fi
            done <<< "${compose_config}"
        fi
    fi
    
    # Strategy 2: Parse docker-compose.yml directly with improved regex
    if [[ -z "${tag}" ]]; then
        while IFS= read -r line || [[ -n "${line}" ]]; do
            # Check if we're entering the service section
            if [[ "${line}" =~ ${service_pattern} ]]; then
                in_service=true
                continue
            fi
            
            # Check if we've left the service section (next top-level key)
            if [[ "${in_service}" == true ]]; then
                # If we hit another service or top-level key, we've passed this service
                if [[ "${line}" =~ ^[[:space:]]*[a-zA-Z][a-zA-Z0-9_-]*:[[:space:]]*$ ]] && [[ ! "${line}" =~ ^[[:space:]]+image: ]]; then
                    # Check if this is a nested key (more indentation) or same level
                    local indent=$(echo "${line}" | sed 's/[^ ].*//' | wc -c)
                    if [[ ${indent} -le 2 ]]; then
                        break
                    fi
                fi
                
                # Look for image line with various formats
                if [[ "${line}" =~ image:[[:space:]]* ]]; then
                    # Extract everything after "image:"
                    local image_value=$(echo "${line}" | sed 's/^[[:space:]]*image:[[:space:]]*//' | sed 's/[[:space:]]*$//')
                    
                    # Remove quotes if present
                    image_value="${image_value//\"/}"
                    image_value="${image_value//\'/}"
                    
                    # Check if this image ends with our image_base (handles any registry prefix)
                    if [[ "${image_value}" =~ /${escaped_base}: ]] || [[ "${image_value}" =~ /${escaped_base}$ ]] || \
                       [[ "${image_value}" =~ ^${escaped_base}: ]] || [[ "${image_value}" == "${escaped_base}" ]]; then
                        # Extract tag (everything after the last colon)
                        if [[ "${image_value}" =~ :([^:]+)$ ]]; then
                            tag="${BASH_REMATCH[1]}"
                        else
                            # No tag specified, default to latest
                            tag="latest"
                        fi
                        break
                    fi
                fi
            fi
        done < "${DOCKER_COMPOSE_FILE}"
    fi
    
    # Strategy 3: Fallback - use grep/awk with flexible pattern matching
    if [[ -z "${tag}" ]]; then
        # Find the service section and extract image line
        local image_line=$(awk -v service="${service_name}" '
            /^[[:space:]]*'"${service_name}"':/ { in_service=1; next }
            in_service && /^[[:space:]]*[a-zA-Z]/ && !/^[[:space:]]*image:/ { 
                if (match($0, /^[[:space:]]*[a-zA-Z]/)) {
                    indent = length($0) - length(ltrim($0))
                    if (indent <= 2) { exit }
                }
            }
            in_service && /image:/ {
                print $0
                exit
            }
            function ltrim(s) { sub(/^[[:space:]]+/, "", s); return s }
        ' "${DOCKER_COMPOSE_FILE}")
        
        if [[ -n "${image_line}" ]]; then
            # Extract tag using flexible pattern that matches any registry prefix
            # Pattern: image: (optional registry/)*image_base:tag
            tag=$(echo "${image_line}" | sed -n "s|.*image:[[:space:]]*[^[:space:]]*/${escaped_base}:\([^[:space:]]*\).*|\1|p" | sed 's/[[:space:]]*$//')
            # If that didn't work, try without registry prefix
            if [[ -z "${tag}" ]]; then
                tag=$(echo "${image_line}" | sed -n "s|.*image:[[:space:]]*${escaped_base}:\([^[:space:]]*\).*|\1|p" | sed 's/[[:space:]]*$//')
            fi
            if [[ -n "${tag}" ]]; then
                # Remove quotes
                tag="${tag//\"/}"
                tag="${tag//\'/}"
            fi
        fi
    fi
    
    # Default to latest if still no tag found
    if [[ -z "${tag}" ]]; then
        # Output warning directly to stderr (force flush to ensure it's separate)
        printf "WARNING: Could not extract tag for '%s' in service '%s', using 'latest'\n" "${image_name}" "${service_name}" >&2
        tag="latest"
    else
        # Clean up tag (remove any trailing whitespace or special chars)
        tag=$(echo "${tag}" | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
    fi

    # Output tag to stdout only (warnings went to stderr)
    # Use printf without newline to avoid extra whitespace
    printf "%s" "${tag}"
    return 0
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

    # Extract tags using improved extract_tag function
    # Capture output and filter out any warning messages that might have been captured
    PANGOLIN_CURRENT=$(extract_tag "pangolin" "fosrl/pangolin" 2>&1 | grep -v "WARNING:" | grep -v "^$" | head -1)
    PANGOLIN_CURRENT=$(echo -n "${PANGOLIN_CURRENT}" | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "${PANGOLIN_CURRENT}" ]] && PANGOLIN_CURRENT="latest"
    log "INFO" "Found Pangolin tag: ${PANGOLIN_CURRENT}"

    GERBIL_CURRENT=$(extract_tag "gerbil" "fosrl/gerbil" 2>&1 | grep -v "WARNING:" | grep -v "^$" | head -1)
    GERBIL_CURRENT=$(echo -n "${GERBIL_CURRENT}" | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "${GERBIL_CURRENT}" ]] && GERBIL_CURRENT="latest"
    log "INFO" "Found Gerbil tag: ${GERBIL_CURRENT}"

    TRAEFIK_CURRENT=$(extract_tag "traefik" "traefik" 2>&1 | grep -v "WARNING:" | grep -v "^$" | head -1)
    TRAEFIK_CURRENT=$(echo -n "${TRAEFIK_CURRENT}" | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -z "${TRAEFIK_CURRENT}" ]] && TRAEFIK_CURRENT="latest"
    log "INFO" "Found Traefik tag: ${TRAEFIK_CURRENT}"

    if [[ "${INCLUDE_CROWDSEC}" == true ]]; then
        CROWDSEC_CURRENT=$(extract_tag "crowdsec" "crowdsecurity/crowdsec" 2>&1 | grep -v "WARNING:" | grep -v "^$" | head -1)
        CROWDSEC_CURRENT=$(echo -n "${CROWDSEC_CURRENT}" | tr -d '\n\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "${CROWDSEC_CURRENT}" ]] && CROWDSEC_CURRENT="latest"
        log "INFO" "Found CrowdSec tag: ${CROWDSEC_CURRENT}"
    fi
    return 0
}
# Interactive tag selection with improved user experience
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
        printf "${CYAN}CrowdSec tag:${NC} ${YELLOW}%s${NC}"
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
    grep "image:" "${DOCKER_COMPOSE_FILE}" > "${update_backup_dir}/old_tags.txt" 2>/dev/null || log "WARNING" "Failed to save current image tags, but continuing"
    [[ -d "./config" ]] && cp -r "./config" "${update_backup_dir}/" || log "WARNING" "Failed to backup config directory, but continuing"
    cp "${DOCKER_COMPOSE_FILE}" "${update_backup_dir}/" || { log "ERROR" "Failed to backup docker-compose.yml"; rm -rf "${update_backup_dir}" 2>/dev/null || true; return 1; }
    
    tar -czf "${archive_path}" -C "${BACKUP_DIR}" "update_${BACKUP_TIMESTAMP}" || { log "ERROR" "Failed to create backup archive: ${archive_path}"; rm -rf "${update_backup_dir}" 2>/dev/null || true; return 1; }
    rm -rf "${update_backup_dir}" 2>/dev/null || true
    log "SUCCESS" "Update backup created successfully: ${archive_path}"
    return 0
}

# Update service image in docker-compose.yml with robust pattern matching
update_service_image() {
    local service_name=$1
    local image_name=$2
    local current_tag=$3
    local new_tag=$4
    local file=$5
    
    if [[ "${current_tag}" == "${new_tag}" ]]; then
        log "INFO" "No change needed for ${service_name} (${current_tag})"
        return 0
    fi
    
    # Create a temporary file
    local tmp_file=$(mktemp)
    local update_successful=false
    local in_service=false
    local service_pattern="^[[:space:]]*${service_name}:"
    local image_pattern="image:[[:space:]]*"
    
    # Process the file line by line with improved matching
    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Check if we're entering the target service section
        if [[ "${line}" =~ ${service_pattern} ]]; then
            in_service=true
            echo "${line}" >> "${tmp_file}"
            continue
        fi
        
        # Check if we've left the service section
        if [[ "${in_service}" == true ]]; then
            # If we hit another top-level service or key, reset flag
            if [[ "${line}" =~ ^[[:space:]]*[a-zA-Z][a-zA-Z0-9_-]*:[[:space:]]*$ ]] && [[ ! "${line}" =~ ^[[:space:]]+image: ]]; then
                local indent=$(echo "${line}" | sed 's/[^ ].*//' | wc -c)
                if [[ ${indent} -le 2 ]]; then
                    in_service=false
                fi
            fi
        fi
        
        # If we're in the target service and this is an image line
        if [[ "${in_service}" == true && "${line}" =~ ${image_pattern} ]]; then
            # Extract the image value
            local image_value=$(echo "${line}" | sed "s/^[[:space:]]*image:[[:space:]]*//" | sed 's/[[:space:]]*$//')
            # Remove quotes
            image_value="${image_value//\"/}"
            image_value="${image_value//\'/}"
            
            # Extract the base image name (the part we need to match)
            # The image_name parameter is the base we're looking for
            local image_base="${image_name}"
            
            # Escape special regex characters in image_base for pattern matching
            local escaped_base=$(printf '%s\n' "${image_base}" | sed 's/[[\.*^$()+?{|]/\\&/g')
            
            # Check if this image ends with our image_base (handles any registry prefix)
            # Match: anything ending with /image_base:tag or /image_base, or just image_base:tag/image_base
            local matched=false
            if [[ "${image_value}" =~ /${escaped_base}: ]] || [[ "${image_value}" =~ /${escaped_base}$ ]] || \
               [[ "${image_value}" =~ ^${escaped_base}: ]] || [[ "${image_value}" == "${escaped_base}" ]]; then
                matched=true
            fi
            
            if [[ "${matched}" == true ]]; then
                # Preserve original indentation and formatting
                local indent=$(echo "${line}" | sed 's/[^ ].*//')
                local quote_char=""
                # Detect if original had quotes
                if [[ "${line}" =~ \" ]]; then
                    quote_char="\""
                elif [[ "${line}" =~ \' ]]; then
                    quote_char="'"
                fi
                
                # Determine the full image name to use (preserve registry prefix if it was there)
                # Extract the registry/namespace part from the original image_value
                local image_prefix="${image_name}"
                
                # If original image had a registry prefix (contains / before the base name), preserve it
                if [[ "${image_value}" =~ ^([^[:space:]]+/)+${escaped_base} ]]; then
                    # Extract everything before the base name (registry/namespace part)
                    local registry_part=$(echo "${image_value}" | sed "s|/${escaped_base}.*||")
                    if [[ -n "${registry_part}" ]]; then
                        # Preserve the registry prefix
                        image_prefix="${registry_part}/${image_base}"
                    fi
                elif [[ "${image_value}" =~ ^${escaped_base} ]]; then
                    # No registry prefix in original, use image_name as-is (might have registry or not)
                    image_prefix="${image_name}"
                fi
                
                # Build new image line preserving format and registry prefix
                echo "${indent}image: ${quote_char}${image_prefix}:${new_tag}${quote_char}" >> "${tmp_file}"
                update_successful=true
                log "SUCCESS" "Updated ${service_name}: ${current_tag} -> ${new_tag}"
            else
                # Not our image, write unchanged
                echo "${line}" >> "${tmp_file}"
            fi
        else
            # Write the line unchanged
            echo "${line}" >> "${tmp_file}"
        fi
    done < "${file}"
    
    if [[ "${update_successful}" == true ]]; then
        # Verify the update before replacing
        # Check if the new tag appears in the file (with any registry prefix)
        local escaped_base=$(printf '%s\n' "${image_name}" | sed 's/[[\.*^$()+?{|]/\\&/g')
        if grep -qE "(/)?${escaped_base}:${new_tag}" "${tmp_file}" 2>/dev/null; then
            mv "${tmp_file}" "${file}" || { 
                log "ERROR" "Failed to update ${file} for ${service_name}"
                rm -f "${tmp_file}" 2>/dev/null || true
                return 1
            }
        else
            log "ERROR" "Update verification failed for ${service_name}"
            rm -f "${tmp_file}" 2>/dev/null || true
            return 1
        fi
        else
        log "ERROR" "Could not find image line for ${service_name} with ${image_name}"
        rm -f "${tmp_file}" 2>/dev/null || true
        return 1
    fi
    
    return 0
}

# Update service images with improved error handling
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
    
    # Create a backup of docker-compose.yml
    cp "${DOCKER_COMPOSE_FILE}" "${DOCKER_COMPOSE_FILE}.bak" || { 
        log "ERROR" "Failed to create backup of docker-compose.yml" 
        return 1
    }
    log "INFO" "Created backup of docker-compose.yml at ${DOCKER_COMPOSE_FILE}.bak"
    
    local max_attempts=3
    local attempt=1
    local shutdown_success=false
    while [[ ${attempt} -le ${max_attempts} && "${shutdown_success}" == false ]]; do
        graceful_shutdown && shutdown_success=true || { log "WARNING" "Shutdown attempt ${attempt}/${max_attempts} failed. Retrying..."; sleep 5; ((attempt++)); }
    done
    [[ "${shutdown_success}" == false ]] && { log "ERROR" "Failed to shutdown services after ${max_attempts} attempts."; return 1; }
    
    # Update image tags in docker-compose.yml
    local update_successful=true
    
    update_service_image "pangolin" "fosrl/pangolin" "${PANGOLIN_CURRENT}" "${PANGOLIN_NEW}" "${DOCKER_COMPOSE_FILE}" || update_successful=false
    update_service_image "gerbil" "fosrl/gerbil" "${GERBIL_CURRENT}" "${GERBIL_NEW}" "${DOCKER_COMPOSE_FILE}" || update_successful=false
    update_service_image "traefik" "traefik" "${TRAEFIK_CURRENT}" "${TRAEFIK_NEW}" "${DOCKER_COMPOSE_FILE}" || update_successful=false
    
    if [[ "${INCLUDE_CROWDSEC}" == true ]]; then
        update_service_image "crowdsec" "crowdsecurity/crowdsec" "${CROWDSEC_CURRENT}" "${CROWDSEC_NEW}" "${DOCKER_COMPOSE_FILE}" || update_successful=false
    fi
    
    if [[ "${update_successful}" == false ]]; then
        if [[ "${INTERACTIVE}" == true ]]; then
            printf "${YELLOW}Some updates failed. Continue anyway? (y/n/c):${NC} "
            local response
            read -r response
            if [[ "${response,,}" == "c" || "${response,,}" != "y" ]]; then
                log "INFO" "Restoring docker-compose.yml from backup..."
                mv "${DOCKER_COMPOSE_FILE}.bak" "${DOCKER_COMPOSE_FILE}" || log "ERROR" "Failed to restore docker-compose.yml from backup!"
                log "INFO" "Update cancelled by user"
                return 1
            fi
        else
            log "ERROR" "Update failed. Restoring from backup..."
            mv "${DOCKER_COMPOSE_FILE}.bak" "${DOCKER_COMPOSE_FILE}" || log "ERROR" "Failed to restore docker-compose.yml from backup!"
            return 1
        fi
    fi
    
    # Pull new images selectively based on include_crowdsec flag
    log "INFO" "Pulling new images..."
    if [[ "${INCLUDE_CROWDSEC}" == true ]]; then
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
    else
        # Skip CrowdSec when pulling if not included
        docker_compose pull pangolin gerbil traefik || {
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
    fi
    
    log "INFO" "Starting updated stack..."
    docker_compose up -d || { 
        log "ERROR" "Failed to start updated stack"
        if [[ "${INTERACTIVE}" == true ]]; then
            printf "${YELLOW}Failed to start the stack. Would you like to restore from backup? (y/n):${NC} "
            local response
            read -r response
            if [[ "${response,,}" == "y" ]]; then
                log "INFO" "Restoring docker-compose.yml from backup..."
                mv "${DOCKER_COMPOSE_FILE}.bak" "${DOCKER_COMPOSE_FILE}" || log "ERROR" "Failed to restore docker-compose.yml from backup!"
                log "INFO" "Attempting to start with original configuration..."
                docker_compose up -d || log "ERROR" "Failed to start stack with original configuration"
            fi
        fi
        return 1
    }
    
    # Remove the backup file if everything was successful
    rm -f "${DOCKER_COMPOSE_FILE}.bak" 2>/dev/null || log "WARNING" "Failed to remove backup file: ${DOCKER_COMPOSE_FILE}.bak"
    
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
    
    create_update_backup || return 1
    get_current_tags || return 1
    get_new_tags
    [[ "${OPERATION_CANCELLED}" == true ]] && { [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }; return 0; }
    update_images || return 1
    log "SUCCESS" "Pangolin stack (with CrowdSec) has been updated successfully"
    return 0
}

# Update without CrowdSec
update_without_crowdsec() {
    print_header "UPDATE PANGOLIN STACK (WITHOUT CROWDSEC)"
    INCLUDE_CROWDSEC=false
    SERVICES=("${SERVICES_BASIC[@]}")
    OPERATION_CANCELLED=false
    
    create_update_backup || return 1
    get_current_tags || return 1
    get_new_tags
    [[ "${OPERATION_CANCELLED}" == true ]] && { [[ "${INTERACTIVE}" == true ]] && { printf "\nPress Enter to return to main menu..."; read -r; }; return 0; }
    update_images || return 1
    log "SUCCESS" "Pangolin stack (without CrowdSec) has been updated successfully"
    return 0
}