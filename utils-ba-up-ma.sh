#!/usr/bin/env bash

# Utility functions for Pangolin stack management

# Colors for terminal output
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly PURPLE='\033[0;35m'
    readonly CYAN='\033[0;36m'
    readonly NC='\033[0m'
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly PURPLE=''
    readonly CYAN=''
    readonly NC=''
fi

# Print usage information
print_usage() {
    printf "Pangolin Backup & Update Management Utility v%s\n\n" "${VERSION}"
    printf "Usage: %s [OPTIONS] [COMMAND]\n\n" "${SCRIPT_NAME}"
    printf "OPTIONS:\n"
    printf "  --cron              Run in non-interactive mode (for cron jobs)\n"
    printf "  --dry-run           Simulate actions without making actual changes\n"
    printf "  --config FILE       Use alternative config file\n"
    printf "  --dir PATH          Override backup directory\n"
    printf "  --help              Show this help message\n\n"
    printf "COMMANDS:\n"
    printf "  backup              Create a backup (default action if no command specified)\n"
    printf "  restore [DIR]       Restore from latest backup or specified backup directory\n"
    printf "  delete [INDEX]      Delete specific backup by index\n"
    printf "  update-basic        Update Pangolin stack (excluding CrowdSec)\n"
    printf "  update-full         Update Pangolin stack (including CrowdSec)\n\n"
    printf "Examples:\n"
    printf "  %s                  Run in interactive mode with menu\n" "${SCRIPT_NAME}"
    printf "  %s backup           Create backup using configured settings\n" "${SCRIPT_NAME}"
    printf "  %s --cron backup    Create backup in non-interactive mode (for cron)\n" "${SCRIPT_NAME}"
    printf "  %s restore backups/20250101_120000  Restore from specific backup\n" "${SCRIPT_NAME}"
    printf "  %s delete 2         Delete backup with index 2\n" "${SCRIPT_NAME}"
    printf "  %s update-full      Update all services including CrowdSec\n" "${SCRIPT_NAME}"
    printf "\n"
}

# Print banners
print_banner() {
    printf "${CYAN}======================================================================${NC}\n"
    printf "${CYAN}   %s${NC}\n" "$1"
    printf "${CYAN}======================================================================${NC}\n\n"
}

# Print section headers
print_header() {
    printf "${CYAN}>> %s${NC}\n\n" "$1"
}

# Print error messages
print_error() {
    printf "${RED}ERROR: %s${NC}\n" "$1" >&2
}

# Print success messages
print_success() {
    printf "${GREEN}SUCCESS: %s${NC}\n" "$1"
}

# Print warning messages
print_warning() {
    printf "${YELLOW}WARNING: %s${NC}\n" "$1"
}

# Print info messages
print_info() {
    printf "${PURPLE}INFO: %s${NC}\n" "$1"
}

# Log messages to file and console
log() {
    local level="$1"
    local message="$2"
    local timestamp="$(date +"%Y-%m-%d %H:%M:%S")"
    
    if [[ -n "${LOG_FILE}" ]]; then
        mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
        printf "[%s] [%s] %s\n" "${timestamp}" "${level}" "${message}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
    
    case "${level}" in
        "ERROR") print_error "${message}" ;;
        "WARNING") print_warning "${message}" ;;
        "SUCCESS") print_success "${message}" ;;
        "INFO") print_info "${message}" ;;
        *) printf "[%s] %s\n" "${level}" "${message}" ;;
    esac
}

# Check dependencies
check_dependencies() {
    local missing_deps=()
    
    for cmd in docker tar grep awk sed; do
        command -v "${cmd}" >/dev/null 2>&1 || missing_deps+=("${cmd}")
    done
    
    if ! command -v docker-compose >/dev/null 2>&1 && ! docker compose version >/dev/null 2>&1; then
        missing_deps+=("docker-compose")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        printf "${RED}ERROR: Missing required dependencies: %s${NC}\n" "${missing_deps[*]}" >&2
        return 1
    fi
    return 0
}

# Check if Docker is running
check_docker() {
    docker info >/dev/null 2>&1 || { log "ERROR" "Docker is not running. Please start Docker and try again."; return 1; }
    return 0
}

# Execute docker compose commands
docker_compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose -f "${DOCKER_COMPOSE_FILE}" "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose -f "${DOCKER_COMPOSE_FILE}" "$@"
    else
        log "ERROR" "Neither 'docker compose' nor 'docker-compose' is available"
        return 1
    fi
}

# Check if stack is running
check_stack() {
    docker_compose ps -q pangolin 2>/dev/null | grep -q . || { log "WARNING" "Pangolin service does not appear to be running."; return 1; }
    docker_compose ps 2>/dev/null | grep -q "Up" || { log "WARNING" "No services appear to be running in the Pangolin stack."; return 1; }
    return 0
}

# Verify service status
verify_services() {
    log "INFO" "Verifying services status..."
    local service_status=$(docker_compose ps)
    log "INFO" "Current service status:"
    printf "%s\n" "${service_status}" | tee -a "${LOG_FILE}" >/dev/null 2>&1 || true
    
    local all_services_up=true
    local service_list=("${SERVICES[@]}")
    
    for service in "${service_list[@]}"; do
        docker_compose ps -q "${service}" 2>/dev/null | grep -q . || { log "ERROR" "Service ${service} does not exist"; all_services_up=false; continue; }
        docker_compose ps "${service}" 2>/dev/null | grep -q "Up" || { log "ERROR" "Service ${service} exists but is not running"; all_services_up=false; }
    done
    
    [[ "${all_services_up}" == false ]] && { log "ERROR" "Not all services are running"; return 1; }
    log "INFO" "All services are running"
    return 0
}

# Cleanup and exit
cleanup_and_exit() {
    local exit_code=$?
    
    if [[ -n "${temp_dir:-}" && -d "${temp_dir}" ]]; then
        rm -rf "${temp_dir}" 2>/dev/null || true
        log "INFO" "Cleaned up temporary directory: ${temp_dir}"
    fi
    
    if [[ "${INTERACTIVE}" == true && ${exit_code} -ne 0 && "${OPERATION_CANCELLED:-false}" != "true" ]]; then
        if [[ "${FUNCNAME[1]}" != "list_backups" && 
              "${FUNCNAME[1]}" != "delete_backups" && 
              "${FUNCNAME[1]}" != "restore_backup" ]]; then
            printf "\n${YELLOW}Script was interrupted or encountered an error.${NC}\n"
            printf "Exiting with code ${exit_code}\n"
        fi
    fi
    
    exit ${exit_code}
}