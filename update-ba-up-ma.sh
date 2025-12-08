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

# Analyze docker-compose file structure for debugging
analyze_docker_compose() {
    local file="$1"
    local show_details="${2:-false}"

    if [[ ! -f "${file}" || ! -r "${file}" ]]; then
        log "ERROR" "Cannot analyze file: ${file}"
        return 1
    fi

    log "INFO" "Analyzing docker-compose file structure..."

    if [[ "${show_details}" == true ]]; then
        log "INFO" "File contents preview (first 20 lines):"
        head -20 "${file}" | while IFS= read -r line; do
            log "DEBUG" "  ${line}"
        done
    fi

    # Check for services section
    if grep -q "^[[:space:]]*services:" "${file}"; then
        log "INFO" "Found 'services:' section"
    else
        log "WARNING" "No 'services:' section found - this may not be a valid docker-compose file"
    fi

    # List all services found
    local services_found=$(grep "^[[:space:]]*[a-zA-Z_-][a-zA-Z0-9_-]*:" "${file}" | grep -v "^[[:space:]]*version:" | grep -v "^[[:space:]]*services:" | sed 's/^[[:space:]]*//' | sed 's/:.*//' | sort | uniq)
    if [[ -n "${services_found}" ]]; then
        log "INFO" "Services found in file: $(echo "${services_found}" | tr '\n' ' ')"
    else
        log "WARNING" "No services found in docker-compose file"
    fi

    # Check for image lines
    local image_count=$(grep -c "^[[:space:]]*image:" "${file}" || true)
    log "INFO" "Found ${image_count} image definitions"

    # Show image lines if in debug mode
    if [[ "${show_details}" == true && ${image_count} -gt 0 ]]; then
        log "INFO" "Image definitions found:"
        grep "^[[:space:]]*image:" "${file}" | while IFS= read -r line; do
            log "DEBUG" "  ${line}"
        done
    fi

    return 0
}

# Extract current image tags with robust YAML parsing
extract_tag() {
    local service_name=$1
    local image_name=$2
    local tag=""
    local debug_output=""

    # Validate inputs
    if [[ -z "${service_name}" || -z "${image_name}" ]]; then
        log "ERROR" "extract_tag: Invalid parameters - service_name and image_name are required"
        printf "latest"
        return 1
    fi

    # Check if docker-compose file exists and is readable
    if [[ ! -f "${DOCKER_COMPOSE_FILE}" || ! -r "${DOCKER_COMPOSE_FILE}" ]]; then
        log "ERROR" "extract_tag: Docker compose file not found or not readable: ${DOCKER_COMPOSE_FILE}"
        printf "latest"
        return 1
    fi

    debug_output+="Service: ${service_name}, Image: ${image_name}\n"

    # Try yq first (most reliable YAML parser)
    if command -v yq &>/dev/null; then
        debug_output+="Using yq for parsing\n"
        # Try different yq syntax variations
        tag=$(yq eval ".services.${service_name}.image" "${DOCKER_COMPOSE_FILE}" 2>/dev/null | sed 's/.*://' || true)
        if [[ -n "${tag}" && "${tag}" != "null" ]]; then
            debug_output+="yq found tag: ${tag}\n"
        else
            # Try alternative yq syntax
            tag=$(yq ".services.${service_name}.image" "${DOCKER_COMPOSE_FILE}" 2>/dev/null | sed 's/.*://' || true)
            if [[ -n "${tag}" && "${tag}" != "null" ]]; then
                debug_output+="yq alt syntax found tag: ${tag}\n"
            fi
        fi
    fi

    # If yq didn't work or isn't available, try improved regex parsing
    if [[ -z "${tag}" || "${tag}" == "null" ]]; then
        debug_output+="Falling back to regex parsing\n"

        # Use awk for more reliable parsing - handles different indentation levels
        tag=$(awk -v service="${service_name}" -v image="${image_name}" '
            BEGIN { in_service = 0; found_image = 0 }
            # Match service definition with flexible indentation
            /^[[:space:]]*services:/ { in_services = 1 }
            in_services && /^[[:space:]]*[^[:space:]]/ && !/^[[:space:]]*services:/ && !/^[[:space:]]*version:/ {
                # Extract service name, handling different indentation
                match($0, /^[[:space:]]*([^:[:space:]]+)/, arr)
                current_service = arr[1]
                in_service = (current_service == service) ? 1 : 0
                next
            }
            in_service && /^[[:space:]]*image:[[:space:]]*/ {
                # Extract image line
                sub(/^[[:space:]]*image:[[:space:]]*/, "")
                if ($0 ~ image ":") {
                    # Extract tag after colon
                    split($0, parts, ":")
                    if (length(parts) >= 2) {
                        found_image = 1
                        print parts[length(parts)]
                        exit
                    }
                }
                next
            }
            END {
                if (!found_image) {
                    exit 1
                }
            }
        ' "${DOCKER_COMPOSE_FILE}" 2>/dev/null || true)

        if [[ -n "${tag}" ]]; then
            debug_output+="Regex parsing found tag: ${tag}\n"
        fi
    fi

    # Final fallback: try simple grep/sed approach
    if [[ -z "${tag}" || "${tag}" == "null" ]]; then
        debug_output+="Trying simple grep/sed fallback\n"

        # Look for the image line more flexibly
        local image_line=$(grep -A 5 "^[[:space:]]*${service_name}:" "${DOCKER_COMPOSE_FILE}" | grep -m 1 "image.*${image_name}" || true)

        if [[ -n "${image_line}" ]]; then
            # Extract tag using multiple approaches
            tag=$(echo "${image_line}" | sed -n 's/.*'"${image_name}"'://p' | sed 's/[[:space:]]*#.*//' | sed 's/[[:space:]]*$//' || true)

            if [[ -n "${tag}" ]]; then
                debug_output+="Simple grep found tag: ${tag}\n"
            fi
        fi
    fi

    # Validate extracted tag
    if [[ -z "${tag}" || "${tag}" == "null" ]]; then
        debug_output+="No tag found, using latest\n"
        log "WARNING" "Could not extract tag for '${image_name}' in service '${service_name}', using 'latest'"
        log "DEBUG" "Tag extraction debug info:\n${debug_output}"
        tag="latest"
    else
        # Clean up the tag (remove quotes, extra spaces)
        tag=$(echo "${tag}" | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/" | sed 's/[[:space:]]*#.*//' | sed 's/[[:space:]]*$//' | sed 's/^[[:space:]]*//')
        debug_output+="Final cleaned tag: ${tag}\n"
        log "DEBUG" "Tag extraction successful: ${service_name} -> ${image_name}:${tag}"
    fi

    printf "%s" "${tag}"
    return 0
}

# Get current tags with enhanced validation
get_current_tags() {
    log "INFO" "Reading current image tags..."

    # Comprehensive file validation
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
                # Recursively call this function with new file path
                get_current_tags
                return $?
            fi
        fi
        PANGOLIN_CURRENT="latest"
        GERBIL_CURRENT="latest"
        TRAEFIK_CURRENT="latest"
        [[ "${INCLUDE_CROWDSEC}" == true ]] && CROWDSEC_CURRENT="latest"
        return 0
    fi

    # Check if file is readable
    if [[ ! -r "${DOCKER_COMPOSE_FILE}" ]]; then
        log "ERROR" "Docker compose file is not readable: ${DOCKER_COMPOSE_FILE}"
        log "INFO" "Please check file permissions and try again"
        PANGOLIN_CURRENT="latest"
        GERBIL_CURRENT="latest"
        TRAEFIK_CURRENT="latest"
        [[ "${INCLUDE_CROWDSEC}" == true ]] && CROWDSEC_CURRENT="latest"
        return 0
    fi

    # Check if file is empty
    if [[ ! -s "${DOCKER_COMPOSE_FILE}" ]]; then
        log "ERROR" "Docker compose file is empty: ${DOCKER_COMPOSE_FILE}"
        PANGOLIN_CURRENT="latest"
        GERBIL_CURRENT="latest"
        TRAEFIK_CURRENT="latest"
        [[ "${INCLUDE_CROWDSEC}" == true ]] && CROWDSEC_CURRENT="latest"
        return 0
    fi

    # Validate basic YAML structure
    if ! head -5 "${DOCKER_COMPOSE_FILE}" | grep -q "^[[:space:]]*version:\|^[[:space:]]*services:"; then
        log "WARNING" "Docker compose file may not be valid YAML. Proceeding with caution."
    fi

    log "INFO" "Docker compose file validation passed: ${DOCKER_COMPOSE_FILE}"

    # Extract tags using improved extract_tag function with error handling
    local extraction_errors=()

    PANGOLIN_CURRENT=$(extract_tag "pangolin" "fosrl/pangolin")
    if [[ "${PANGOLIN_CURRENT}" == "latest" ]]; then
        extraction_errors+=("pangolin")
    fi
    log "INFO" "Found Pangolin tag: ${PANGOLIN_CURRENT}"

    GERBIL_CURRENT=$(extract_tag "gerbil" "fosrl/gerbil")
    if [[ "${GERBIL_CURRENT}" == "latest" ]]; then
        extraction_errors+=("gerbil")
    fi
    log "INFO" "Found Gerbil tag: ${GERBIL_CURRENT}"

    TRAEFIK_CURRENT=$(extract_tag "traefik" "traefik")
    if [[ "${TRAEFIK_CURRENT}" == "latest" ]]; then
        extraction_errors+=("traefik")
    fi
    log "INFO" "Found Traefik tag: ${TRAEFIK_CURRENT}"

    if [[ "${INCLUDE_CROWDSEC}" == true ]]; then
        CROWDSEC_CURRENT=$(extract_tag "crowdsec" "crowdsecurity/crowdsec")
        if [[ "${CROWDSEC_CURRENT}" == "latest" ]]; then
            extraction_errors+=("crowdsec")
        fi
        log "INFO" "Found CrowdSec tag: ${CROWDSEC_CURRENT}"
    fi

    # Report extraction issues
    if [[ ${#extraction_errors[@]} -gt 0 ]]; then
        log "WARNING" "Tag extraction failed for services: ${extraction_errors[*]}"
        log "INFO" "This may indicate issues with the docker-compose.yml file format or structure"
        log "INFO" "The update will proceed with 'latest' tags, but you may want to verify the docker-compose.yml file"

        # Offer to analyze the file in interactive mode
        if [[ "${INTERACTIVE}" == true ]]; then
            printf "\n${YELLOW}Would you like to analyze the docker-compose file structure? (y/n):${NC} "
            local analyze_response
            read -r analyze_response
            if [[ "${analyze_response,,}" == "y" ]]; then
                analyze_docker_compose "${DOCKER_COMPOSE_FILE}" true
                printf "\n${YELLOW}Press Enter to continue...${NC} "
                read -r
            fi
        fi
    else
        log "SUCCESS" "All image tags extracted successfully"
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

# Update service image in docker-compose.yml with improved pattern matching
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
    local service_pattern="^  ${service_name}:"
    
    # Process the file line by line for more precise control
    while IFS= read -r line; do
        # Check if we're in the target service section
        if [[ "${line}" =~ ${service_pattern} ]]; then
            in_service=true
        elif [[ "${in_service}" == true && "${line}" =~ ^[[:space:]]{2}[a-z] ]]; then
            # We've reached the next service, reset the flag
            in_service=false
        fi
        
        # If we're in the target service and this is the image line
        if [[ "${in_service}" == true && "${line}" =~ image:[[:space:]]*${image_name}:${current_tag} ]]; then
            # Replace the tag
            echo "${line//:${current_tag}/:${new_tag}}" >> "${tmp_file}"
            update_successful=true
            log "SUCCESS" "Updated ${service_name}: ${current_tag} -> ${new_tag}"
        else
            # Write the line unchanged
            echo "${line}" >> "${tmp_file}"
        fi
    done < "${file}"
    
    if [[ "${update_successful}" == true ]]; then
        mv "${tmp_file}" "${file}" || { 
            log "ERROR" "Failed to update ${file} for ${service_name}"
            rm -f "${tmp_file}" 2>/dev/null || true
            return 1
        }
    else
        log "WARNING" "Pattern not found for ${service_name} with ${image_name}:${current_tag}"
        rm -f "${tmp_file}" 2>/dev/null || true
        
        # Try a more flexible approach if exact match failed
        log "INFO" "Attempting flexible pattern matching for ${service_name}..."
        
        local tmp_file2=$(mktemp)
        local update_successful2=false
        local in_service=false
        
        while IFS= read -r line; do
            # Check if we're in the target service section
            if [[ "${line}" =~ ${service_pattern} ]]; then
                in_service=true
            elif [[ "${in_service}" == true && "${line}" =~ ^[[:space:]]{2}[a-z] ]]; then
                # We've reached the next service, reset the flag
                in_service=false
            fi
            
            # If we're in the target service and this is an image line
            if [[ "${in_service}" == true && "${line}" =~ image:[[:space:]]*${image_name}: ]]; then
                # Replace with new tag, regardless of current tag
                echo "    image: ${image_name}:${new_tag}" >> "${tmp_file2}"
                update_successful2=true
                log "SUCCESS" "Updated ${service_name} with flexible matching: -> ${new_tag}"
            else
                # Write the line unchanged
                echo "${line}" >> "${tmp_file2}"
            fi
        done < "${file}"
        
        if [[ "${update_successful2}" == true ]]; then
            mv "${tmp_file2}" "${file}" || { 
                log "ERROR" "Failed to update ${file} for ${service_name} with flexible matching"
                rm -f "${tmp_file2}" 2>/dev/null || true
                return 1
            }
        else
            log "ERROR" "Could not update image tag for ${service_name} even with flexible matching"
            rm -f "${tmp_file2}" 2>/dev/null || true
            return 1
        fi
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
                ${DOCKER_COMPOSE_CMD} up -d || log "ERROR" "Failed to start stack with original configuration"
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