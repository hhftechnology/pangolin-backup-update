#!/usr/bin/env bash

# Docker Update Check & Automation

# Use safer bash settings but allow some flexibility
set -eo pipefail

# Script metadata
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly VERSION="1.0.0"

# Source utility scripts
source "${SCRIPT_DIR}/utils-ba-up-ma.sh" || { echo "ERROR: Failed to load utils"; exit 1; }
source "${SCRIPT_DIR}/docker-update-utils.sh" || { echo "ERROR: Failed to load docker-update-utils"; exit 1; }
source "${SCRIPT_DIR}/docker-update-config.sh" || { echo "ERROR: Failed to load docker-update-config"; exit 1; }
source "${SCRIPT_DIR}/docker-update-notify.sh" || { echo "ERROR: Failed to load docker-update-notify"; exit 1; }

# Global variables
DOCKER_COMPOSE_FILE="${DOCKER_COMPOSE_FILE:-./docker-compose.yml}"
LOG_FILE="${LOG_FILE:-/tmp/docker-update-check.log}"
INTERACTIVE=true
DRY_RUN=false

# Command line options (override config)
OPT_AUTO_UPDATE=""
OPT_NOTIFY_ONLY=""
OPT_INCLUDE=""
OPT_EXCLUDE=""
OPT_LABEL=""
OPT_BACKUP_DAYS=""
OPT_PRUNE=""
OPT_FORCE_RECREATE=""
OPT_CONFIG_FILE=""
OPT_TEST_NOTIFY=false

# Print usage
print_usage() {
    cat << EOF
Pangolin Docker Update Check & Automation v${VERSION}

Usage: ${SCRIPT_NAME} [OPTIONS]

OPTIONS:
  -h, --help              Show this help message
  -v, --version           Show version information
  -c, --config FILE       Use specified configuration file
  -f, --compose FILE      Docker compose file to use (default: ./docker-compose.yml)

UPDATE BEHAVIOR:
  -a, --auto              Automatically update containers without prompting
  -n, --notify-only       Only check and notify, don't update
  -y, --yes               Answer yes to all prompts (use with caution)
  --dry-run               Simulate actions without making changes

FILTERING:
  -i, --include NAMES     Include only these containers (comma-separated)
  -e, --exclude NAMES     Exclude these containers (comma-separated)
  -l, --label FILTER      Only process containers with label (format: key=value)
  --min-age AGE           Only update containers older than AGE (e.g., "7d", "2w")

UPDATE OPTIONS:
  -b, --backup-days N     Backup images for N days before updating (0=no backup)
  -p, --prune             Prune dangling images after update
  --force-recreate        Force recreate containers even if config unchanged

UTILITY:
  --configure             Run interactive configuration wizard
  --test-notify           Send test notification
  --list-backups          List all backup images
  --cleanup-backups N     Remove backup images older than N days

EXAMPLES:
  # Check for updates and prompt
  ${SCRIPT_NAME}

  # Auto-update all containers
  ${SCRIPT_NAME} --auto

  # Check only, send notifications
  ${SCRIPT_NAME} --notify-only

  # Update specific containers with backup
  ${SCRIPT_NAME} --include "pangolin,gerbil" --backup-days 7

  # Exclude containers and prune after update
  ${SCRIPT_NAME} --exclude "traefik,crowdsec" --prune

  # Update containers with specific label
  ${SCRIPT_NAME} --label "auto-update=true" --auto

  # Dry run to see what would be updated
  ${SCRIPT_NAME} --dry-run

  # Configure settings interactively
  ${SCRIPT_NAME} --configure

  # Test notification setup
  ${SCRIPT_NAME} --test-notify

CRON EXAMPLES:
  # Check daily at 9 AM, notify only
  0 9 * * * /path/to/${SCRIPT_NAME} --notify-only --config ~/.pangolin/update.conf

  # Auto-update weekly on Sunday at 2 AM with backup and prune
  0 2 * * 0 /path/to/${SCRIPT_NAME} --auto --backup-days 7 --prune

EOF
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                print_usage
                exit 0
                ;;
            -v|--version)
                echo "Pangolin Docker Update Check v${VERSION}"
                exit 0
                ;;
            -c|--config)
                OPT_CONFIG_FILE="$2"
                shift 2
                ;;
            -f|--compose)
                DOCKER_COMPOSE_FILE="$2"
                shift 2
                ;;
            -a|--auto)
                OPT_AUTO_UPDATE=true
                shift
                ;;
            -n|--notify-only)
                OPT_NOTIFY_ONLY=true
                shift
                ;;
            -y|--yes)
                INTERACTIVE=false
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -i|--include)
                OPT_INCLUDE="$2"
                shift 2
                ;;
            -e|--exclude)
                OPT_EXCLUDE="$2"
                shift 2
                ;;
            -l|--label)
                OPT_LABEL="$2"
                shift 2
                ;;
            --min-age)
                UPDATE_MIN_AGE="$2"
                shift 2
                ;;
            -b|--backup-days)
                OPT_BACKUP_DAYS="$2"
                shift 2
                ;;
            -p|--prune)
                OPT_PRUNE=true
                shift
                ;;
            --force-recreate)
                OPT_FORCE_RECREATE=true
                shift
                ;;
            --configure)
                configure_update_settings
                exit 0
                ;;
            --test-notify)
                OPT_TEST_NOTIFY=true
                shift
                ;;
            --list-backups)
                list_backup_images
                exit 0
                ;;
            --cleanup-backups)
                cleanup_old_backups "$2"
                exit 0
                ;;
            *)
                echo "ERROR: Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done
}

# Main update check function
check_for_updates() {
    log "INFO" "Starting Docker update check..."

    # Check dependencies
    check_dependencies || { log "ERROR" "Missing dependencies"; return 1; }
    check_docker || { log "ERROR" "Docker not available"; return 1; }

    # Discover containers
    log "INFO" "Discovering containers..."
    local containers=($(discover_containers "${DOCKER_COMPOSE_FILE}" "${UPDATE_USE_COMPOSE}"))

    if [[ ${#containers[@]} -eq 0 ]]; then
        log "WARNING" "No containers found"
        return 0
    fi

    log "INFO" "Found ${#containers[@]} container(s)"

    # Check each container for updates
    local updates_available=()
    local updates_json=""
    local checked_count=0
    local filtered_count=0

    log "INFO" "Starting update check loop..."

    for container_id in "${containers[@]}"; do
        log "INFO" "Processing container ID: ${container_id}"
        # Get container info
        local info=$(get_container_info "${container_id}")
        if [[ $? -ne 0 ]]; then
            log "WARNING" "Failed to get info for container ${container_id}"
            continue
        fi
        IFS='|' read -r container_name image status created <<< "${info}"
        log "INFO" "Container: ${container_name}, Image: ${image}"

        # Apply filters
        local include_filter="${OPT_INCLUDE:-${UPDATE_INCLUDE_CONTAINERS}}"
        local exclude_filter="${OPT_EXCLUDE:-${UPDATE_EXCLUDE_CONTAINERS}}"
        local label_filter="${OPT_LABEL:-${UPDATE_LABEL_FILTER}}"

        # Check name filters (capture return code to avoid exit on failure)
        container_matches_filter "${container_name}" "${include_filter}" "${exclude_filter}"
        local name_match=$?
        if [[ ${name_match} -ne 0 ]]; then
            log "INFO" "Skipping ${container_name} (filtered by name)"
            ((filtered_count++))
            continue
        fi

        # Check label filter (capture return code to avoid exit on failure)
        container_has_label "${container_id}" "${label_filter}"
        local label_match=$?
        if [[ ${label_match} -ne 0 ]]; then
            log "INFO" "Skipping ${container_name} (filtered by label)"
            ((filtered_count++))
            continue
        fi

        # Check age filter
        if [[ -n "${UPDATE_MIN_AGE}" ]]; then
            local min_age_days=$(parse_age_filter "${UPDATE_MIN_AGE}")
            container_older_than "${container_id}" "${min_age_days}"
            local age_match=$?
            if [[ ${age_match} -ne 0 ]]; then
                log "INFO" "Skipping ${container_name} (too new: min age ${UPDATE_MIN_AGE})"
                ((filtered_count++))
                continue
            fi
        fi

        ((checked_count++))
        log "INFO" "Checking ${container_name} (${image})..."

        # Get current digest
        local current_digest=$(get_container_digest "${container_id}" 2>&1)

        if [[ -z "${current_digest}" ]]; then
            log "WARNING" "Could not get digest for ${container_name}, skipping (container may not have digest info)"
            continue
        fi

        log "INFO" "Current digest: ${current_digest:0:20}..."

        # Get registry digest
        log "INFO" "Querying registry for ${image}..."
        local registry_digest=$(get_registry_digest "${image}" 2>&1)

        if [[ -z "${registry_digest}" ]]; then
            log "WARNING" "Could not query registry for ${image}, skipping (no digest returned)"
            continue
        fi

        log "INFO" "Registry digest: ${registry_digest:0:20}..."

        # Compare digests (capture return code to avoid exit on failure)
        digests_match "${current_digest}" "${registry_digest}"
        local digests_same=$?
        if [[ ${digests_same} -ne 0 ]]; then
            log "INFO" "Update available for ${container_name}"
            updates_available+=("${container_name}|${image}|${current_digest}|${registry_digest}")
        else
            log "INFO" "${container_name} is up to date"
        fi
    done

    log "INFO" "Checked ${checked_count} container(s), filtered ${filtered_count}"

    # Report results
    local update_count=${#updates_available[@]}

    if [[ ${checked_count} -eq 0 ]]; then
        log "WARNING" "No containers were checked. Possible reasons:"
        log "WARNING" "  - All containers filtered out"
        log "WARNING" "  - Containers don't have digest information"
        log "WARNING" "  - Registry queries are failing"
        log "INFO" "Try running with verbose logging or check /tmp/docker-update-check.log"
        return 0
    fi

    if [[ ${update_count} -eq 0 ]]; then
        log "SUCCESS" "All containers are up to date!"

        # Send notification if configured
        if [[ "${UPDATE_NOTIFY_ENABLED}" == "true" ]]; then
            send_notifications "Docker Update Check" "All containers are up to date." "normal" "{}"
        fi

        return 0
    fi

    # Display updates
    printf "\n${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}║            Updates Available: %-3d                             ║${NC}\n" "${update_count}"
    printf "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n\n"

    local index=1
    for update_info in "${updates_available[@]}"; do
        IFS='|' read -r container image current_digest new_digest <<< "${update_info}"
        printf "${YELLOW}[%d]${NC} ${GREEN}%s${NC}\n" "${index}" "${container}"
        printf "    Image: ${CYAN}%s${NC}\n" "${image}"
        printf "    Status: ${YELLOW}Update available${NC}\n\n"
        ((index++))
    done

    # Build notification message
    local notify_message=$(build_update_message "${update_count}" "${updates_available[@]}")

    # Send notifications
    if [[ "${UPDATE_NOTIFY_ENABLED}" == "true" ]]; then
        send_notifications "Docker Updates Available" "${notify_message}" "high" "{\"count\":${update_count}}"
    fi

    # Handle update mode
    local notify_only="${OPT_NOTIFY_ONLY:-${UPDATE_NOTIFY_ONLY}}"
    local auto_update="${OPT_AUTO_UPDATE:-${UPDATE_AUTO_UPDATE}}"

    if [[ "${notify_only}" == "true" ]]; then
        log "INFO" "Notify-only mode: not performing updates"
        return 0
    fi

    if [[ "${auto_update}" != "true" && "${INTERACTIVE}" == "true" ]]; then
        printf "${YELLOW}Proceed with updates? (y/N):${NC} "
        local confirm
        read -r confirm
        if [[ "${confirm,,}" != "y" ]]; then
            log "INFO" "Updates cancelled by user"
            return 0
        fi
    fi

    # Perform updates
    perform_updates "${updates_available[@]}"
}

# Perform container updates
perform_updates() {
    local updates=("$@")
    local updated_containers=()
    local failed_containers=()

    local backup_days="${OPT_BACKUP_DAYS:-${UPDATE_BACKUP_DAYS}}"
    local auto_prune="${OPT_PRUNE:-${UPDATE_AUTO_PRUNE}}"
    local force_recreate="${OPT_FORCE_RECREATE:-${UPDATE_FORCE_RECREATE}}"

    log "INFO" "Starting update process..."

    # Cleanup old backups first
    if [[ ${backup_days} -gt 0 ]]; then
        cleanup_old_backups "${backup_days}"
    fi

    for update_info in "${updates[@]}"; do
        IFS='|' read -r container_name image current_digest new_digest <<< "${update_info}"

        log "INFO" "Updating ${container_name}..."

        # Get container ID
        local container_id=$(docker ps -q -f "name=^${container_name}$" 2>/dev/null)

        if [[ -z "${container_id}" ]]; then
            log "ERROR" "Container not found: ${container_name}"
            failed_containers+=("${container_name}")
            continue
        fi

        # Backup image if configured
        if [[ ${backup_days} -gt 0 ]]; then
            if [[ "${DRY_RUN}" == "true" ]]; then
                log "INFO" "DRY-RUN: Would backup ${container_name}"
            else
                backup_container_image "${container_id}" "${backup_days}" || log "WARNING" "Backup failed for ${container_name}"
            fi
        fi

        # Update container
        if [[ "${DRY_RUN}" == "true" ]]; then
            log "INFO" "DRY-RUN: Would update ${container_name}"
            updated_containers+=("${container_name}")
        else
            if update_container_compose "${container_id}" "${DOCKER_COMPOSE_FILE}" "${force_recreate}"; then
                updated_containers+=("${container_name}")
                log "SUCCESS" "Updated ${container_name}"
            else
                # Try standalone update
                if update_container_standalone "${container_id}" "${force_recreate}"; then
                    updated_containers+=("${container_name}")
                    log "SUCCESS" "Updated ${container_name}"
                else
                    failed_containers+=("${container_name}")
                    log "ERROR" "Failed to update ${container_name}"
                fi
            fi
        fi
    done

    # Prune if configured
    if [[ "${auto_prune}" == "true" ]]; then
        if [[ "${DRY_RUN}" == "true" ]]; then
            log "INFO" "DRY-RUN: Would prune dangling images"
        else
            prune_dangling_images
        fi
    fi

    # Report results
    local updated_count=${#updated_containers[@]}
    local failed_count=${#failed_containers[@]}

    printf "\n${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}║                    Update Summary                              ║${NC}\n"
    printf "${CYAN}╠════════════════════════════════════════════════════════════════╣${NC}\n"
    printf "${CYAN}║${NC} ${GREEN}✓ Updated:${NC} %-49d ${CYAN}║${NC}\n" "${updated_count}"
    printf "${CYAN}║${NC} ${RED}✗ Failed:${NC}  %-49d ${CYAN}║${NC}\n" "${failed_count}"
    printf "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}\n\n"

    if [[ ${updated_count} -gt 0 ]]; then
        printf "${GREEN}Updated containers:${NC}\n"
        for container in "${updated_containers[@]}"; do
            printf "  ✓ %s\n" "${container}"
        done
        printf "\n"
    fi

    if [[ ${failed_count} -gt 0 ]]; then
        printf "${RED}Failed containers:${NC}\n"
        for container in "${failed_containers[@]}"; do
            printf "  ✗ %s\n" "${container}"
        done
        printf "\n"
    fi

    # Send completion notification
    if [[ "${UPDATE_NOTIFY_ENABLED}" == "true" && ${updated_count} -gt 0 ]]; then
        local completion_msg=$(build_completion_message "${updated_count}" "${failed_count}" "${updated_containers[@]}")
        send_notifications "Docker Update Complete" "${completion_msg}" "normal" "{\"updated\":${updated_count},\"failed\":${failed_count}}"
    fi

    return 0
}

# List backup images
list_backup_images() {
    log "INFO" "Listing backup images..."

    local backups=$(docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}' | grep '^dockcheck/' 2>/dev/null)

    if [[ -z "${backups}" ]]; then
        log "INFO" "No backup images found"
        return 0
    fi

    printf "\n${CYAN}Backup Images:${NC}\n\n"
    echo "${backups}" | head -1
    echo "${backups}" | tail -n +2
    printf "\n"
}

# Main function
main() {
    # Parse command line arguments
    parse_args "$@"

    # Load configuration
    load_update_config "${OPT_CONFIG_FILE}"

    # Ensure all variables are initialized (prevent unbound variable errors)
    UPDATE_INCLUDE_CONTAINERS="${UPDATE_INCLUDE_CONTAINERS:-}"
    UPDATE_EXCLUDE_CONTAINERS="${UPDATE_EXCLUDE_CONTAINERS:-}"
    UPDATE_LABEL_FILTER="${UPDATE_LABEL_FILTER:-}"
    UPDATE_MIN_AGE="${UPDATE_MIN_AGE:-}"
    UPDATE_NOTIFY_ENABLED="${UPDATE_NOTIFY_ENABLED:-false}"
    UPDATE_NOTIFY_CHANNELS="${UPDATE_NOTIFY_CHANNELS:-}"
    UPDATE_AUTO_UPDATE="${UPDATE_AUTO_UPDATE:-false}"
    UPDATE_NOTIFY_ONLY="${UPDATE_NOTIFY_ONLY:-false}"
    UPDATE_BACKUP_DAYS="${UPDATE_BACKUP_DAYS:-0}"
    UPDATE_AUTO_PRUNE="${UPDATE_AUTO_PRUNE:-false}"
    UPDATE_FORCE_RECREATE="${UPDATE_FORCE_RECREATE:-false}"

    # Override config with command line options
    [[ -n "${OPT_AUTO_UPDATE}" ]] && UPDATE_AUTO_UPDATE="${OPT_AUTO_UPDATE}"
    [[ -n "${OPT_NOTIFY_ONLY}" ]] && UPDATE_NOTIFY_ONLY="${OPT_NOTIFY_ONLY}"
    [[ -n "${OPT_INCLUDE}" ]] && UPDATE_INCLUDE_CONTAINERS="${OPT_INCLUDE}"
    [[ -n "${OPT_EXCLUDE}" ]] && UPDATE_EXCLUDE_CONTAINERS="${OPT_EXCLUDE}"
    [[ -n "${OPT_LABEL}" ]] && UPDATE_LABEL_FILTER="${OPT_LABEL}"
    [[ -n "${OPT_BACKUP_DAYS}" ]] && UPDATE_BACKUP_DAYS="${OPT_BACKUP_DAYS}"
    [[ -n "${OPT_PRUNE}" ]] && UPDATE_AUTO_PRUNE="${OPT_PRUNE}"
    [[ -n "${OPT_FORCE_RECREATE}" ]] && UPDATE_FORCE_RECREATE="${OPT_FORCE_RECREATE}"

    # Validate configuration
    validate_update_config

    # Handle test notification
    if [[ "${OPT_TEST_NOTIFY}" == "true" ]]; then
        test_notifications
        exit 0
    fi

    # Print banner
    if [[ "${INTERACTIVE}" == "true" ]]; then
        print_banner "DOCKER UPDATE CHECK & AUTOMATION"
    fi

    # Run update check
    check_for_updates

    log "INFO" "Update check completed"
}

# Run main function
main "$@"
