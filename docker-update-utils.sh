#!/usr/bin/env bash

# Docker Update Utilities
# Utility functions for Docker image update detection and automation

# Get image digest from registry using Docker Registry API v2
# Supports Docker Hub, GHCR, and custom registries
get_registry_digest() {
    local image_full=${1:-}

    if [[ -z "${image_full}" ]]; then
        return 1
    fi

    # Check if curl is available
    if ! command -v curl >/dev/null 2>&1; then
        echo "ERROR: curl is required for registry queries" >&2
        return 1
    fi
    local registry=""
    local repository=""
    local tag="latest"
    local auth_header=""

    # Parse image name: [registry/]repository[:tag]
    if [[ "${image_full}" =~ ^([^/]+\.[^/]+)/(.+):(.+)$ ]]; then
        # Custom registry with tag: registry.example.com/repo/image:tag
        registry="${BASH_REMATCH[1]}"
        repository="${BASH_REMATCH[2]}"
        tag="${BASH_REMATCH[3]}"
    elif [[ "${image_full}" =~ ^([^/]+\.[^/]+)/(.+)$ ]]; then
        # Custom registry without tag: registry.example.com/repo/image
        registry="${BASH_REMATCH[1]}"
        repository="${BASH_REMATCH[2]}"
        tag="latest"
    elif [[ "${image_full}" =~ ^([^/]+)/([^:]+):(.+)$ ]]; then
        # Docker Hub with namespace and tag: user/image:tag or ghcr.io/user/image:tag
        local first_part="${BASH_REMATCH[1]}"
        if [[ "${first_part}" == "ghcr.io" || "${first_part}" == "docker.io" ]]; then
            registry="${first_part}"
            repository="${BASH_REMATCH[2]}"
        else
            registry="docker.io"
            repository="${first_part}/${BASH_REMATCH[2]}"
        fi
        tag="${BASH_REMATCH[3]}"
    elif [[ "${image_full}" =~ ^([^/]+)/([^:]+)$ ]]; then
        # Docker Hub with namespace, no tag: user/image
        registry="docker.io"
        repository="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        tag="latest"
    elif [[ "${image_full}" =~ ^([^:]+):(.+)$ ]]; then
        # Official image with tag: image:tag
        registry="docker.io"
        repository="library/${BASH_REMATCH[1]}"
        tag="${BASH_REMATCH[2]}"
    else
        # Official image without tag: image
        registry="docker.io"
        repository="library/${image_full}"
        tag="latest"
    fi

    # Get authentication token for the registry
    if [[ "${registry}" == "docker.io" ]]; then
        # Docker Hub authentication
        local token=$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repository}:pull" 2>/dev/null | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
        [[ -n "${token}" ]] && auth_header="Authorization: Bearer ${token}"
    elif [[ "${registry}" == "ghcr.io" ]]; then
        # GitHub Container Registry - anonymous access for public repos
        # For private repos, would need: -H "Authorization: Bearer ${GITHUB_TOKEN}"
        auth_header=""
    fi

    # Query registry for image manifest
    local registry_url="https://${registry}"
    [[ "${registry}" == "docker.io" ]] && registry_url="https://registry-1.docker.io"

    local manifest_url="${registry_url}/v2/${repository}/manifests/${tag}"

    # Get manifest digest
    local digest=""
    if [[ -n "${auth_header}" ]]; then
        digest=$(curl -fsSL -H "${auth_header}" -H "Accept: application/vnd.docker.distribution.manifest.v2+json" -H "Accept: application/vnd.oci.image.manifest.v1+json" -I "${manifest_url}" 2>/dev/null | grep -i "docker-content-digest:" | awk '{print $2}' | tr -d '\r')
    else
        digest=$(curl -fsSL -H "Accept: application/vnd.docker.distribution.manifest.v2+json" -H "Accept: application/vnd.oci.image.manifest.v1+json" -I "${manifest_url}" 2>/dev/null | grep -i "docker-content-digest:" | awk '{print $2}' | tr -d '\r')
    fi

    # Fallback: try docker manifest inspect if curl method failed
    if [[ -z "${digest}" ]] && command -v docker >/dev/null 2>&1; then
        digest=$(docker manifest inspect "${image_full}" 2>/dev/null | grep -o '"digest"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
    fi

    # Only echo if we got a digest
    if [[ -n "${digest}" ]]; then
        echo "${digest}"
        return 0
    else
        return 1
    fi
}

# Get running container's image digest
get_container_digest() {
    local container_id=${1:-}

    if [[ -z "${container_id}" ]]; then
        return 1
    fi

    if ! command -v docker >/dev/null 2>&1; then
        return 1
    fi

    # Get the image ID/digest that the container is running
    local image_id=$(docker inspect --format='{{.Image}}' "${container_id}" 2>/dev/null)

    if [[ -z "${image_id}" ]]; then
        return 1
    fi

    # Get the RepoDigest from the image
    local repo_digests=$(docker inspect --format='{{range .RepoDigests}}{{.}} {{end}}' "${image_id}" 2>/dev/null)

    # Extract the digest (sha256:...)
    local digest=$(echo "${repo_digests}" | grep -o 'sha256:[a-f0-9]*' | head -1)

    # Fallback: use image ID if no RepoDigest available (local builds)
    if [[ -z "${digest}" ]]; then
        digest="${image_id}"
    fi

    echo "${digest}"
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
    local container_id=$1

    local name=$(docker inspect --format='{{.Name}}' "${container_id}" 2>/dev/null | sed 's/^\///')
    local image=$(docker inspect --format='{{.Config.Image}}' "${container_id}" 2>/dev/null)
    local status=$(docker inspect --format='{{.State.Status}}' "${container_id}" 2>/dev/null)
    local created=$(docker inspect --format='{{.Created}}' "${container_id}" 2>/dev/null)

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

# Compare two digests
digests_match() {
    local digest1=$1
    local digest2=$2

    # Remove any whitespace
    digest1=$(echo "${digest1}" | xargs)
    digest2=$(echo "${digest2}" | xargs)

    # Empty digests don't match
    if [[ -z "${digest1}" || -z "${digest2}" ]]; then
        return 1
    fi

    # Compare
    if [[ "${digest1}" == "${digest2}" ]]; then
        return 0
    else
        return 1
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
