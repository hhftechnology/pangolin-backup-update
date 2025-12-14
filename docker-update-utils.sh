#!/usr/bin/env bash

# Docker Update Utilities
# Utility functions for Docker image update detection and automation
# Following dockcheck logic from https://github.com/mag37/dockcheck

# Global variables for tools
REGCTL_BIN=""
TIMEOUT_CMD="timeout"

# Setup regctl binary (following dockcheck's approach)
setup_regctl() {
    # Check if regctl is already available
    if command -v regctl >/dev/null 2>&1; then
        REGCTL_BIN="regctl"
        return 0
    fi

    # Check for local installation
    local local_regctl="${HOME}/.docker/cli-plugins/regctl"
    if [[ -x "${local_regctl}" ]]; then
        REGCTL_BIN="${local_regctl}"
        return 0
    fi

    # Try to download regctl
    log "INFO" "regctl not found, attempting to download..."

    local regctl_dir="${HOME}/.docker/cli-plugins"
    mkdir -p "${regctl_dir}"

    local arch="amd64"
    local os="linux"
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l) arch="armv7" ;;
    esac

    local regctl_url="https://github.com/regclient/regclient/releases/latest/download/regctl-${os}-${arch}"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "${regctl_url}" -o "${local_regctl}" && chmod +x "${local_regctl}"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "${regctl_url}" -O "${local_regctl}" && chmod +x "${local_regctl}"
    else
        log "ERROR" "Cannot download regctl: neither curl nor wget available"
        return 1
    fi

    if [[ -x "${local_regctl}" ]]; then
        REGCTL_BIN="${local_regctl}"
        log "SUCCESS" "Downloaded regctl successfully"
        return 0
    else
        log "ERROR" "Failed to download or install regctl"
        return 1
    fi
}

# Setup timeout command (following dockcheck's approach)
setup_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        TIMEOUT_CMD="timeout"
    elif command -v gtimeout >/dev/null 2>&1; then
        TIMEOUT_CMD="gtimeout"
    else
        TIMEOUT_CMD=""
    fi
}

# Get image digest from registry using regctl (dockcheck method)
# This is much more reliable than curl-based API calls
get_registry_digest() {
    local image_full=${1:-}

    if [[ -z "${image_full}" ]]; then
        return 1
    fi

    # Ensure regctl is available
    if [[ -z "${REGCTL_BIN}" ]]; then
        setup_regctl || return 1
    fi

    # Query registry using regctl (dockcheck method)
    local timeout_val="${UPDATE_REGISTRY_TIMEOUT:-10}"
    local reg_hash=""

    if [[ -n "${TIMEOUT_CMD}" ]]; then
        reg_hash=$("${TIMEOUT_CMD}" "${timeout_val}" "${REGCTL_BIN}" -v error image digest --list "${image_full}" 2>&1)
    else
        reg_hash=$("${REGCTL_BIN}" -v error image digest --list "${image_full}" 2>&1)
    fi

    local exit_code=$?

    if [[ ${exit_code} -eq 0 && -n "${reg_hash}" ]]; then
        echo "${reg_hash}"
        return 0
    else
        # If regctl fails, try docker manifest as fallback
        if command -v docker >/dev/null 2>&1; then
            local manifest_digest=$(docker manifest inspect "${image_full}" 2>/dev/null | grep -o '"digest"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
            if [[ -n "${manifest_digest}" ]]; then
                echo "${manifest_digest}"
                return 0
            fi
        fi
        return 1
    fi
}

# Get running container's image digest (dockcheck method)
get_container_digest() {
    local container_id=${1:-}

    if [[ -z "${container_id}" ]]; then
        return 1
    fi

    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi

    # Following dockcheck: get Image ID first, then RepoDigests
    local image_id=$(docker inspect "${container_id}" --format='{{.Image}}' 2>/dev/null)

    if [[ -z "${image_id}" ]]; then
        return 1
    fi

    # Get RepoDigests list from the image (this is what we compare against)
    local local_hash=$(docker image inspect "${image_id}" --format='{{.RepoDigests}}' 2>/dev/null)

    if [[ -n "${local_hash}" ]]; then
        echo "${local_hash}"
        return 0
    else
        # No RepoDigests - likely a local build
        echo "${image_id}"
        return 0
    fi
}

# Check if container matches include/exclude filters
container_matches_filter() {
    local container_name=$1
    local include_filter=$2
    local exclude_filter=$3

    # Check exclude filter first
    if [[ -n "${exclude_filter}" ]]; then
        IFS=',' read -ra EXCLUDE_LIST <<< "${exclude_filter}"
        for pattern in "${EXCLUDE_LIST[@]}"; do
            pattern=$(echo "${pattern}" | xargs)  # trim whitespace
            if [[ "${container_name}" == ${pattern} ]]; then
                return 1  # excluded
            fi
        done
    fi

    # If include filter is empty, include all (that weren't excluded)
    if [[ -z "${include_filter}" ]]; then
        return 0  # included
    fi

    # Check include filter
    IFS=',' read -ra INCLUDE_LIST <<< "${include_filter}"
    for pattern in "${INCLUDE_LIST[@]}"; do
        pattern=$(echo "${pattern}" | xargs)  # trim whitespace
        if [[ "${container_name}" == ${pattern} ]]; then
            return 0  # included
        fi
    done

    return 1  # not included
}

# Check if container has required label
container_has_label() {
    local container_id=$1
    local label_filter=$2

    if [[ -z "${label_filter}" ]]; then
        return 0  # no filter, so include
    fi

    # Parse label filter: key=value
    local label_key=$(echo "${label_filter}" | cut -d'=' -f1)
    local label_value=$(echo "${label_filter}" | cut -d'=' -f2-)

    # Get container labels
    local container_labels=$(docker inspect --format='{{range $key, $value := .Config.Labels}}{{$key}}={{$value}}{{"\n"}}{{end}}' "${container_id}" 2>/dev/null)

    # Check if label exists with correct value
    if echo "${container_labels}" | grep -q "^${label_key}=${label_value}$"; then
        return 0  # has label
    fi

    return 1  # doesn't have label
}

# Discover containers from docker-compose file or all running containers
discover_containers() {
    local compose_file=$1
    local use_compose=${2:-false}

    local containers=()

    if [[ "${use_compose}" == "true" && -f "${compose_file}" ]]; then
        # Get containers from docker-compose file
        if docker compose version >/dev/null 2>&1; then
            containers=($(docker compose -f "${compose_file}" ps -q 2>/dev/null))
        elif command -v docker-compose >/dev/null 2>&1; then
            containers=($(docker-compose -f "${compose_file}" ps -q 2>/dev/null))
        fi
    else
        # Get all running containers
        containers=($(docker ps -q 2>/dev/null))
    fi

    echo "${containers[@]}"
}

# Get container info (name, image, status)
get_container_info() {
    local container_id=${1:-}

    if [[ -z "${container_id}" ]]; then
        echo "unknown|unknown|unknown|unknown"
        return 1
    fi

    local name=$(docker inspect --format='{{.Name}}' "${container_id}" 2>/dev/null | sed 's/^\///')
    local image=$(docker inspect --format='{{.Config.Image}}' "${container_id}" 2>/dev/null)
    local status=$(docker inspect --format='{{.State.Status}}' "${container_id}" 2>/dev/null)
    local created=$(docker inspect --format='{{.Created}}' "${container_id}" 2>/dev/null)

    if [[ -z "${name}" || -z "${image}" ]]; then
        echo "unknown|unknown|unknown|unknown"
        return 1
    fi

    echo "${name}|${image}|${status}|${created}"
}

# Backup container image before update
backup_container_image() {
    local container_id=${1:-}
    local backup_days=${2:-0}

    local container_name=$(docker inspect --format='{{.Name}}' "${container_id}" 2>/dev/null | sed 's/^\///')
    local image=$(docker inspect --format='{{.Config.Image}}' "${container_id}" 2>/dev/null)

    if [[ -z "${image}" || -z "${container_name}" ]]; then
        return 1
    fi

    # Create backup tag: dockcheck/container:YYYY-MM-DD_HHMM_tag
    local backup_timestamp=$(date +"%Y-%m-%d_%H%M")
    local original_tag="${image##*:}"
    [[ "${original_tag}" == "${image}" ]] && original_tag="latest"

    local backup_tag="dockcheck/${container_name}:${backup_timestamp}_${original_tag}"

    # Tag current image as backup
    if docker tag "${image}" "${backup_tag}" 2>/dev/null; then
        log "INFO" "Created backup image: ${backup_tag}"
        return 0
    else
        log "WARNING" "Failed to create backup for ${container_name}"
        return 1
    fi
}

# Cleanup old backup images
cleanup_old_backups() {
    local backup_days=${1:-0}

    if [[ -z "${backup_days}" || "${backup_days}" -le 0 ]]; then
        return 0
    fi

    # Get all backup images
    local backup_images=$(docker images --format '{{.Repository}}:{{.Tag}}|{{.CreatedAt}}' | grep '^dockcheck/' 2>/dev/null)

    if [[ -z "${backup_images}" ]]; then
        return 0
    fi

    local cutoff_date=$(date -d "${backup_days} days ago" +%s 2>/dev/null || date -v-${backup_days}d +%s 2>/dev/null)

    while IFS='|' read -r image_tag created_at; do
        # Parse creation date
        local image_date=$(date -d "${created_at}" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "${created_at}" +%s 2>/dev/null)

        if [[ -n "${image_date}" && "${image_date}" -lt "${cutoff_date}" ]]; then
            log "INFO" "Removing old backup image: ${image_tag}"
            docker rmi "${image_tag}" 2>/dev/null || log "WARNING" "Failed to remove ${image_tag}"
        fi
    done <<< "${backup_images}"
}

# Prune dangling images
prune_dangling_images() {
    log "INFO" "Pruning dangling images..."

    local pruned=$(docker image prune -f 2>&1)

    if echo "${pruned}" | grep -q "Total reclaimed space"; then
        local reclaimed=$(echo "${pruned}" | grep "Total reclaimed space" | awk '{print $4" "$5}')
        log "SUCCESS" "Pruned dangling images. Reclaimed: ${reclaimed}"
    else
        log "INFO" "No dangling images to prune"
    fi
}

# Compare local and registry digests (dockcheck method)
# Uses string matching: if LocalHash contains RegHash, they match
digests_match() {
    local local_hash=${1:-}
    local reg_hash=${2:-}

    # Empty digests don't match
    if [[ -z "${local_hash}" || -z "${reg_hash}" ]]; then
        return 1
    fi

    # Following dockcheck: check if local hash contains registry hash
    # This handles cases where local_hash is a list like "[docker.io/image@sha256:abc...]"
    if [[ "${local_hash}" == *"${reg_hash}"* ]]; then
        return 0  # Match - no update needed
    else
        return 1  # No match - update available
    fi
}

# Get container's compose service name (if from compose)
get_compose_service() {
    local container_id=$1
    local compose_file=$2

    if [[ ! -f "${compose_file}" ]]; then
        echo ""
        return
    fi

    # Get container labels
    local service_label=$(docker inspect --format='{{index .Config.Labels "com.docker.compose.service"}}' "${container_id}" 2>/dev/null)

    echo "${service_label}"
}

# Update container using docker-compose
update_container_compose() {
    local container_id=${1:-}
    local compose_file=${2:-}
    local force_recreate=${3:-false}

    local service=$(get_compose_service "${container_id}" "${compose_file}")

    if [[ -z "${service}" ]]; then
        log "ERROR" "Container is not managed by docker-compose"
        return 1
    fi

    log "INFO" "Pulling new image for service: ${service}"

    # Pull new image
    if docker compose version >/dev/null 2>&1; then
        docker compose -f "${compose_file}" pull "${service}" || return 1

        # Recreate container
        if [[ "${force_recreate}" == "true" ]]; then
            docker compose -f "${compose_file}" up -d --force-recreate "${service}" || return 1
        else
            docker compose -f "${compose_file}" up -d "${service}" || return 1
        fi
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose -f "${compose_file}" pull "${service}" || return 1

        # Recreate container
        if [[ "${force_recreate}" == "true" ]]; then
            docker-compose -f "${compose_file}" up -d --force-recreate "${service}" || return 1
        else
            docker-compose -f "${compose_file}" up -d "${service}" || return 1
        fi
    else
        log "ERROR" "docker-compose not available"
        return 1
    fi

    log "SUCCESS" "Updated container: ${service}"
    return 0
}

# Update standalone container (not from compose)
update_container_standalone() {
    local container_id=${1:-}
    local force_recreate=${2:-false}

    local container_name=$(docker inspect --format='{{.Name}}' "${container_id}" 2>/dev/null | sed 's/^\///')
    local image=$(docker inspect --format='{{.Config.Image}}' "${container_id}" 2>/dev/null)

    if [[ -z "${image}" || -z "${container_name}" ]]; then
        log "ERROR" "Failed to get container info"
        return 1
    fi

    log "INFO" "Pulling new image: ${image}"
    docker pull "${image}" || { log "ERROR" "Failed to pull ${image}"; return 1; }

    # Get container's run command (simplified recreation)
    log "WARNING" "Standalone container updates require manual recreation"
    log "INFO" "Run: docker stop ${container_name} && docker rm ${container_name}"
    log "INFO" "Then recreate with your original docker run command using the new image"

    return 1  # Return error to indicate manual intervention needed
}

# Parse age filter (e.g., "7d", "2w", "1m")
parse_age_filter() {
    local age_str=$1

    if [[ -z "${age_str}" ]]; then
        echo "0"
        return
    fi

    # Extract number and unit
    local number=$(echo "${age_str}" | grep -o '^[0-9]*')
    local unit=$(echo "${age_str}" | grep -o '[dwmy]$')

    if [[ -z "${number}" ]]; then
        echo "0"
        return
    fi

    # Convert to days
    case "${unit}" in
        d) echo "${number}" ;;
        w) echo "$((number * 7))" ;;
        m) echo "$((number * 30))" ;;
        y) echo "$((number * 365))" ;;
        *) echo "${number}" ;;  # assume days if no unit
    esac
}

# Check if container is older than specified age
container_older_than() {
    local container_id=$1
    local min_age_days=$2

    if [[ -z "${min_age_days}" || "${min_age_days}" -le 0 ]]; then
        return 0  # no age filter
    fi

    # Get container creation time
    local created=$(docker inspect --format='{{.Created}}' "${container_id}" 2>/dev/null)

    if [[ -z "${created}" ]]; then
        return 1
    fi

    # Convert to timestamp
    local created_ts=$(date -d "${created}" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%S" "${created%%.*}" +%s 2>/dev/null)
    local current_ts=$(date +%s)
    local age_seconds=$((current_ts - created_ts))
    local age_days=$((age_seconds / 86400))

    if [[ "${age_days}" -ge "${min_age_days}" ]]; then
        return 0  # older than threshold
    else
        return 1  # newer than threshold
    fi
}
