#!/usr/bin/env bash

# Notification helper functions
# These ensure notifications are sent even if script exits

# Send notification if enabled (wrapper to handle exit scenarios)
send_notification_if_enabled() {
    local title=$1
    local message=$2
    local priority=${3:-normal}
    local updates_json=${4:-"{}"}

    if [[ "${UPDATE_NOTIFY_ENABLED}" == "true" ]]; then
        send_notifications "${title}" "${message}" "${priority}" "${updates_json}"
    fi
}

# Send check summary notification (always sent, even on early exit)
send_check_summary_notification() {
    local checked_count=$1
    local updates_count=$2
    local errors_count=$3
    shift 3
    local updates_list=("$@")

    if [[ "${UPDATE_NOTIFY_ENABLED}" != "true" ]]; then
        return 0
    fi

    local title="Docker Update Check Complete"
    local message=""
    local priority="normal"

    # Build summary message
    message+="Checked: ${checked_count} container(s)\n"
    message+="Updates Available: ${updates_count}\n"
    message+="Errors: ${errors_count}\n"

    if [[ ${updates_count} -gt 0 ]]; then
        priority="high"
        message+="\nContainers with updates:\n"
        for update_info in "${updates_list[@]}"; do
            IFS='|' read -r container image _ _ <<< "${update_info}"
            message+="  • ${container} (${image})\n"
        done
    fi

    send_notifications "${title}" "${message}" "${priority}" "{\"checked\":${checked_count},\"updates\":${updates_count},\"errors\":${errors_count}}"
}

# Trap handler to ensure notifications on exit
notification_exit_handler() {
    local exit_code=$?

    if [[ "${UPDATE_NOTIFY_ENABLED}" == "true" && ${exit_code} -ne 0 ]]; then
        # Script exited with error, send notification
        send_notifications "Docker Update Check Failed" "Update check exited with error code: ${exit_code}\n\nCheck logs for details." "high" "{\"exit_code\":${exit_code}}"
    fi
}

# Set up exit trap for notifications
setup_notification_trap() {
    trap notification_exit_handler EXIT
}
