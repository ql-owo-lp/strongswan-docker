#!/bin/bash

# This script builds and pushes a multi-architecture Docker image for strongSwan.
# It creates images for both amd64 (standard PCs, servers) and arm64 (Raspberry Pi, etc.).

# Exit immediately if a command exits with a non-zero status for better error handling.
set -e

# --- Configuration ---
# The name of the final image, including your Docker Hub username.
readonly IMAGE_NAME="${1:-iowoi/strongswan}"
# The target architectures for the build.
readonly PLATFORMS="linux/amd64,linux/arm64,linux/arm/v7"
# The directory containing the Dockerfile and entrypoint.sh script.
readonly BUILD_CONTEXT="docker"

# --- Pre-flight Checks ---
# Check if the build context directory exists.
if [ ! -d "$BUILD_CONTEXT" ]; then
    echo "Error: Build context directory '$BUILD_CONTEXT' not found." >&2
    echo "Please ensure your Dockerfile and entrypoint.sh are inside a folder named '$BUILD_CONTEXT'." >&2
    exit 1
fi

# Check if the user is logged into Docker. Pushing to a registry requires authentication.
# The script will continue, but the final 'push' step will fail if not logged in.
if ! docker info | grep -q "Username:"; then
    echo "Warning: You do not appear to be logged into Docker Hub." >&2
    echo "Please run 'docker login' before executing this script for the push to succeed." >&2
fi

echo "--- Setting up Docker Buildx Builder ---"
# Create a new builder instance if one doesn't already exist. This is necessary for multi-arch builds.
# This setup is idempotent, so it's safe to run every time.
if ! docker buildx ls | grep -q "multiarchbuilder"; then
    echo "Creating new builder instance 'multiarchbuilder'..."
    docker buildx create --name multiarchbuilder --use --bootstrap
else
    echo "Using existing builder instance 'multiarchbuilder'."
    docker buildx use multiarchbuilder
fi

# --- Build Logic ---
# Check if running in E2E test mode to avoid multi-arch builds and pushing to a registry.
if [ "$E2E_TESTING" = "true" ]; then
    echo "--- Building Single-arch Image for E2E Test: ${IMAGE_NAME} ---"
    # For local tests, we build for the host architecture and load it into the local daemon.
    # This is faster and avoids Docker Hub rate limits.
    docker buildx build \
        --platform "linux/amd64" \
        --tag "${IMAGE_NAME}:latest" \
        --load \
        "${BUILD_CONTEXT}"
    echo
    echo "--- E2E Test Build Complete! ---"
    echo "Single-arch image '${IMAGE_NAME}:latest' is now loaded into the local Docker daemon."
else
    echo "--- Building and Pushing Multi-arch Image: ${IMAGE_NAME} ---"
    echo "Target platforms: ${PLATFORMS}"
    # The 'buildx build' command builds for all specified platforms and pushes the
    # manifest list (which points to the platform-specific images) to the registry.
    docker buildx build \
        --platform "${PLATFORMS}" \
        --tag "${IMAGE_NAME}:latest" \
        --push \
        "${BUILD_CONTEXT}"
    echo
    echo "--- Build and Push Complete! ---"
    echo "Multi-arch image '${IMAGE_NAME}:latest' is now available on Docker Hub."
    echo "You can inspect it with the command:"
    echo "  docker buildx imagetools inspect ${IMAGE_NAME}:latest"
fi
