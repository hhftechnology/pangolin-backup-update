#!/usr/bin/env bash

# Pangolin Stack Backup & Management Master Script
# Entry point for managing backups and updates

# Set strict error handling
set -o nounset
set -o pipefail
IFS=$'\n\t'

# Script version
readonly VERSION="1.0.4"

# Default configuration
readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEFAULT_BACKUP_DIR="${SCRIPT_DIR}/backups"
readonly DEFAULT_CONFIG_FILE="${SCRIPT_DIR}/.pangolin-backup.conf"
readonly DEFAULT_RETENTION_DAYS=60
readonly DEFAULT_BACKUP_ITEMS=("docker-compose.yml" "config")

# Docker compose configuration
readonly DOCKER_COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
readonly CONFIG_DIR="${SCRIPT_DIR}/config"

# Service definitions
readonly SERVICES_BASIC=("pangolin" "gerbil" "traefik")
readonly SERVICES_WITH_CROWDSEC=("pangolin" "gerbil" "crowdsec" "traefik")

# Global variables
BACKUP_DIR=""
RETENTION_DAYS=""
BACKUP_ITEMS=()
CONFIG_FILE="${DEFAULT_CONFIG_FILE}"
LOG_FILE=""
readonly BACKUP_TIMESTAMP="$(date +"%Y%m%d_%H%M%S")"
PANGOLIN_DIR="${SCRIPT_DIR}"
DRY_RUN=false
INTERACTIVE=true
INCLUDE_CROWDSEC=true
SERVICES=("${SERVICES_WITH_CROWDSEC[@]}")
temp_dir=""
OPERATION_CANCELLED=false

# Source modular scripts
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/config.sh"
source "${SCRIPT_DIR}/backup.sh"
source "${SCRIPT_DIR}/update.sh"
source "${SCRIPT_DIR}/cron.sh"

# Set trap for cleanup
trap cleanup_and_exit SIGINT SIGTERM EXIT

# Parse command-line arguments
parse_arguments() {
    COMMAND=""
    COMMAND_ARG=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --cron) INTERACTIVE=false; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --config) [[ -n "${2:-}" ]] && { CONFIG_FILE="$2"; shift 2; } || { print_error "Missing argument for --config"; exit 1; } ;;
            --dir) [[ -n "${2:-}" ]] && { BACKUP_DIR="$2"; shift 2; } || { print_error "Missing argument for --dir"; exit 1; } ;;
            --help) print_usage; exit 0 ;;
            backup|restore|delete|update-basic|update-full)
                COMMAND="$1"
                shift
                if [[ "${COMMAND}" == "restore" && -n "${1:-}" && "${1:0:1}" != "-" ]]; then
                    COMMAND_ARG="$1"
                    shift
                elif [[ "${COMMAND}" == "delete" && -n "${1:-}" && "${1:0:1}" != "-" ]]; then
                    COMMAND_ARG="$1"
                    shift
                fi
                ;;
            *) print_error "Unknown option or command: $1"; print_usage; exit 1 ;;
        esac
    done
}

# Show main menu
show_main_menu() {
    local exit_menu=false
    OPERATION_CANCELLED=false
    
    while [[ "${exit_menu}" == false ]]; do
        clear
        print_banner "PANGOLIN BACKUP & UPDATE MANAGEMENT UTILITY"
        printf "${CYAN}Current Configuration:${NC}\n"
        printf "Backup Directory:  ${YELLOW}%s${NC}\n" "${BACKUP_DIR}"
        printf "Retention Period:  ${YELLOW}%d days${NC}\n" "${RETENTION_DAYS}"
        printf "Backup Items:      ${YELLOW}%d items${NC}\n" "${#BACKUP_ITEMS[@]}"
        printf "\n${CYAN}Backup & Restore Options:${NC}\n"
        printf "1. Create Backup\n"
        printf "2. Restore from Backup\n"
        printf "3. List Available Backups\n"
        printf "4. Delete Specific Backups\n"
        printf "5. Configure Backup Settings (Use with Caution)\n"
        printf "6. Setup Cron Job\n"
        printf "\n${CYAN}Update Options:${NC}\n"
        printf "7. Update Stack (excluding CrowdSec)\n"
        printf "8. Update Stack (including CrowdSec)\n"
        printf "\n9. Exit\n\n"
        printf "Enter your choice [1-9]: "
        local choice
        read -r choice
        
        case "${choice}" in
            1) create_backup ;;
            2) restore_backup ;;
            3) list_backups ;;
            4) delete_backups ;;
            5) configure_backup ;;
            6) setup_cron_job ;;
            7) update_without_crowdsec ;;
            8) update_with_crowdsec ;;
            9) exit_menu=true ;;
            *) log "ERROR" "Invalid choice."; sleep 2 ;;
        esac
        [[ "${exit_menu}" == false ]] && { printf "\nPress Enter to continue..."; read -r; }
    done
}

# Main execution
main() {
    check_dependencies || exit 1
    parse_arguments "$@"
    load_config
    validate_backup_dir
    
    if [[ -n "${COMMAND}" ]]; then
        case "${COMMAND}" in
            backup)
                create_backup && log "SUCCESS" "Backup completed successfully at $(date)" || log "ERROR" "Backup failed at $(date)"
                [[ "${INTERACTIVE}" == false ]] && exit $?
                ;;
            restore) restore_backup "${COMMAND_ARG}"; [[ "${INTERACTIVE}" == false ]] && exit $? ;;
            delete)
                if [[ -n "${COMMAND_ARG}" && "${COMMAND_ARG}" =~ ^[0-9]+$ ]]; then
                    list_backups || { log "ERROR" "No backups available."; [[ "${INTERACTIVE}" == false ]] && exit 1; }
                    if [[ "${COMMAND_ARG}" -ge "${#BACKUPS_ARRAY[@]}" ]]; then
                        log "ERROR" "Invalid backup index: ${COMMAND_ARG}"
                        [[ "${INTERACTIVE}" == false ]] && exit 1
                    else
                        local backup_to_delete="${BACKUPS_ARRAY[${COMMAND_ARG}]}"
                        [[ "${DRY_RUN}" == true ]] && log "INFO" "DRY-RUN: Would delete backup: $(basename "${backup_to_delete}")" || { rm -f "${backup_to_delete}" && log "SUCCESS" "Deleted backup: $(basename "${backup_to_delete}")" || log "ERROR" "Failed to delete backup: $(basename "${backup_to_delete}")"; }
                        [[ "${INTERACTIVE}" == false ]] && exit $?
                    fi
                else
                    delete_backups
                    [[ "${INTERACTIVE}" == false ]] && exit $?
                fi
                ;;
            update-basic)
                INCLUDE_CROWDSEC=false
                update_without_crowdsec && log "SUCCESS" "Update (basic) completed successfully at $(date)" || log "ERROR" "Update (basic) failed at $(date)"
                [[ "${INTERACTIVE}" == false ]] && exit $?
                ;;
            update-full)
                INCLUDE_CROWDSEC=true
                update_with_crowdsec && log "SUCCESS" "Update (full) completed successfully at $(date)" || log "ERROR" "Update (full) failed at $(date)"
                [[ "${INTERACTIVE}" == false ]] && exit $?
                ;;
        esac
        [[ "${INTERACTIVE}" == true ]] && show_main_menu
    fi
    
    [[ "${INTERACTIVE}" == true ]] && show_main_menu || { create_backup && exit 0 || exit 1; }
    exit 0
}

main "$@"