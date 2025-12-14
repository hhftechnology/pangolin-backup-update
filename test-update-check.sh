#!/usr/bin/env bash

# Simple diagnostic script to test update check functionality

echo "=== Docker Update Check Diagnostic ==="
echo

# Check Docker
echo "1. Checking Docker..."
if command -v docker >/dev/null 2>&1; then
    echo "   ✓ Docker found: $(docker --version)"
else
    echo "   ✗ Docker not found!"
    exit 1
fi

# Check docker-compose
echo
echo "2. Checking docker-compose..."
if docker compose version >/dev/null 2>&1; then
    echo "   ✓ docker compose found: $(docker compose version)"
elif command -v docker-compose >/dev/null 2>&1; then
    echo "   ✓ docker-compose found: $(docker-compose --version)"
else
    echo "   ✗ docker-compose not found!"
fi

# Check curl
echo
echo "3. Checking curl..."
if command -v curl >/dev/null 2>&1; then
    echo "   ✓ curl found: $(curl --version | head -1)"
else
    echo "   ✗ curl not found! (required for registry queries)"
fi

# List containers
echo
echo "4. Listing running containers..."
docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}"

# Count containers
CONTAINER_COUNT=$(docker ps -q | wc -l)
echo
echo "   Total running containers: ${CONTAINER_COUNT}"

# Test getting container info
echo
echo "5. Testing container info retrieval..."
FIRST_CONTAINER=$(docker ps -q | head -1)
if [[ -n "${FIRST_CONTAINER}" ]]; then
    echo "   Testing with container: ${FIRST_CONTAINER}"
    NAME=$(docker inspect --format='{{.Name}}' "${FIRST_CONTAINER}" 2>/dev/null | sed 's/^\///')
    IMAGE=$(docker inspect --format='{{.Config.Image}}' "${FIRST_CONTAINER}" 2>/dev/null)
    echo "   Name: ${NAME}"
    echo "   Image: ${IMAGE}"

    # Test getting digest
    echo
    echo "6. Testing digest retrieval..."
    IMAGE_ID=$(docker inspect --format='{{.Image}}' "${FIRST_CONTAINER}" 2>/dev/null)
    REPO_DIGESTS=$(docker inspect --format='{{range .RepoDigests}}{{.}} {{end}}' "${IMAGE_ID}" 2>/dev/null)
    if [[ -n "${REPO_DIGESTS}" ]]; then
        echo "   ✓ Container has digest: ${REPO_DIGESTS}"
    else
        echo "   ✗ Container has no RepoDigest (was it pulled from a registry?)"
        echo "   Image ID: ${IMAGE_ID}"
    fi

    # Test registry query
    echo
    echo "7. Testing registry query for ${IMAGE}..."
    if command -v curl >/dev/null 2>&1; then
        # Try docker manifest first
        if docker manifest inspect "${IMAGE}" >/dev/null 2>&1; then
            MANIFEST_DIGEST=$(docker manifest inspect "${IMAGE}" 2>/dev/null | grep -o '"digest"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | cut -d'"' -f4)
            echo "   ✓ Registry query successful"
            echo "   Manifest digest: ${MANIFEST_DIGEST}"
        else
            echo "   ✗ docker manifest inspect failed"
            echo "   This might be a rate limit issue or authentication problem"
            echo "   Try: docker login"
        fi
    else
        echo "   ✗ curl not available, cannot query registry"
    fi
else
    echo "   ✗ No containers found to test"
fi

# Test running the update check script
echo
echo "8. Testing update check script..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/docker-update-check.sh" ]]; then
    echo "   Running: ./docker-update-check.sh --dry-run"
    echo "   ===================="
    "${SCRIPT_DIR}/docker-update-check.sh" --dry-run 2>&1 | head -50
    EXIT_CODE=${PIPESTATUS[0]}
    echo "   ===================="
    echo "   Exit code: ${EXIT_CODE}"
else
    echo "   ✗ docker-update-check.sh not found"
fi

echo
echo "=== Diagnostic Complete ==="
