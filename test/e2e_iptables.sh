#!/bin/bash
set -eo pipefail

# --- Test Configuration ---
TEST_IMAGE_NAME="strongswan-e2e-test"
DEFAULT_PREFIX="STRONGSWAN"
CUSTOM_PREFIX="TESTVPN"
CONTAINER_DEFAULT="e2e-default"
CONTAINER_CUSTOM="e2e-custom"
CONTAINER_UNCLEAN="e2e-unclean"
CONTAINER_CLEANUP="e2e-cleanup"

# --- Helper Functions ---
info() {
    echo "[INFO] $1"
}

pass() {
    echo -e "\e[32m[PASS]\e[0m $1"
}

fail() {
    echo -e "\e[31m[FAIL]\e[0m $1"
    # In case of failure, run a final cleanup to not leave a mess
    cleanup_all >/dev/null 2>&1
    exit 1
}

# Checks if an iptables chain exists in a given table
chain_exists() {
    local table=$1
    local chain=$2
    sudo iptables -t "$table" -L "$chain" >/dev/null 2>&1
}

# Checks if a jump rule to our custom chain exists
jump_rule_exists() {
    local table=$1
    local src_chain=$2
    local dest_chain=$3
    sudo iptables -t "$table" -C "$src_chain" -j "$dest_chain" >/dev/null 2>&1
}

# --- Cleanup Functions ---
cleanup_chains() {
    local prefix=$1
    info "Cleaning up chains with prefix '${prefix}'..."
    if jump_rule_exists nat POSTROUTING "${prefix}_NAT"; then
        sudo iptables -t nat -D POSTROUTING -j "${prefix}_NAT"
    fi
    if jump_rule_exists filter FORWARD "${prefix}_FORWARD"; then
        sudo iptables -D FORWARD -j "${prefix}_FORWARD"
    fi
    if chain_exists nat "${prefix}_NAT"; then
        sudo iptables -t nat -F "${prefix}_NAT"
        sudo iptables -t nat -X "${prefix}_NAT"
    fi
    if chain_exists filter "${prefix}_FORWARD"; then
        sudo iptables -F "${prefix}_FORWARD"
        sudo iptables -X "${prefix}_FORWARD"
    fi
}

cleanup_containers() {
    info "Removing test containers..."
    for container in $CONTAINER_DEFAULT $CONTAINER_CUSTOM $CONTAINER_UNCLEAN $CONTAINER_CLEANUP; do
        if [ "$(docker ps -a -q -f name=^/${container}$)" ]; then
            docker rm -f "$container" >/dev/null
        fi
    done
}

cleanup_all() {
    info "Performing full cleanup..."
    cleanup_containers
    cleanup_chains "$DEFAULT_PREFIX"
    cleanup_chains "$CUSTOM_PREFIX"
    if [ "$(docker images -q ${TEST_IMAGE_NAME})" ]; then
        info "Removing test Docker image..."
        docker rmi -f "${TEST_IMAGE_NAME}"
    fi
}

# --- Test Cases ---

# Test 1: Verifies rules are created and removed for a default instance
test_default_instance() {
    info "--- Running Test: Default Instance ---"

    # Run container in host network mode to allow it to modify host iptables
    info "Starting container with default settings..."
    docker run -d --rm --name "$CONTAINER_DEFAULT" \
        --net=host \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        "$TEST_IMAGE_NAME"
    sleep 5 # Give it time to initialize

    # Verify creation
    info "Verifying rules creation..."
    chain_exists nat "${DEFAULT_PREFIX}_NAT" || fail "NAT chain was not created"
    chain_exists filter "${DEFAULT_PREFIX}_FORWARD" || fail "FORWARD chain was not created"
    jump_rule_exists nat POSTROUTING "${DEFAULT_PREFIX}_NAT" || fail "NAT jump rule was not created"
    jump_rule_exists filter FORWARD "${DEFAULT_PREFIX}_FORWARD" || fail "FORWARD jump rule was not created"
    pass "Default iptables rules created successfully."

    # Stop container and verify cleanup
    info "Stopping container..."
    docker stop "$CONTAINER_DEFAULT"
    sleep 2

    info "Verifying rules cleanup..."
    ! chain_exists nat "${DEFAULT_PREFIX}_NAT" || fail "NAT chain was not cleaned up"
    ! chain_exists filter "${DEFAULT_PREFIX}_FORWARD" || fail "FORWARD chain was not cleaned up"
    pass "Default iptables rules cleaned up successfully."
    info "--- Test Finished: Default Instance ---"
}

# Test 2: Verifies rules are created and removed for an instance with a custom prefix
test_custom_prefix_instance() {
    info "--- Running Test: Custom Prefix Instance ---"

    # Run container in host network mode
    info "Starting container with custom prefix '${CUSTOM_PREFIX}'..."
    docker run -d --rm --name "$CONTAINER_CUSTOM" \
        --net=host \
        -e IPTABLES_CHAIN_PREFIX="$CUSTOM_PREFIX" \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        "$TEST_IMAGE_NAME"
    sleep 5

    # Verify creation
    info "Verifying rules creation..."
    chain_exists nat "${CUSTOM_PREFIX}_NAT" || fail "Custom NAT chain was not created"
    chain_exists filter "${CUSTOM_PREFIX}_FORWARD" || fail "Custom FORWARD chain was not created"
    jump_rule_exists nat POSTROUTING "${CUSTOM_PREFIX}_NAT" || fail "Custom NAT jump rule was not created"
    jump_rule_exists filter FORWARD "${CUSTOM_PREFIX}_FORWARD" || fail "Custom FORWARD jump rule was not created"
    pass "Custom iptables rules created successfully."

    # Stop container and verify cleanup
    info "Stopping container..."
    docker stop "$CONTAINER_CUSTOM"
    sleep 2

    info "Verifying rules cleanup..."
    ! chain_exists nat "${CUSTOM_PREFIX}_NAT" || fail "Custom NAT chain was not cleaned up"
    ! chain_exists filter "${CUSTOM_PREFIX}_FORWARD" || fail "Custom FORWARD chain was not cleaned up"
    pass "Custom iptables rules cleaned up successfully."
    info "--- Test Finished: Custom Prefix Instance ---"
}

# Test 3: Verifies a new container cleans up orphaned rules from a crashed one
test_unclean_shutdown() {
    info "--- Running Test: Unclean Shutdown ---"

    # Start a container and verify its rules
    info "Starting initial container..."
    docker run -d --rm --name "$CONTAINER_UNCLEAN" \
        --net=host \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        "$TEST_IMAGE_NAME"
    sleep 5
    chain_exists nat "${DEFAULT_PREFIX}_NAT" || fail "Initial container failed to create NAT chain"
    pass "Initial container created rules."

    # Kill it to simulate a crash
    info "Forcefully killing container to simulate crash..."
    docker kill "$CONTAINER_UNCLEAN"
    sleep 2

    # Verify rules are now orphaned
    info "Verifying rules are orphaned..."
    chain_exists nat "${DEFAULT_PREFIX}_NAT" || fail "Orphaned NAT chain does not exist"
    chain_exists filter "${DEFAULT_PREFIX}_FORWARD" || fail "Orphaned FORWARD chain does not exist"
    pass "Rules are successfully orphaned."

    # Start a new container that should clean up the old rules
    info "Starting cleanup container..."
    docker run -d --rm --name "$CONTAINER_CLEANUP" \
        --net=host \
        --cap-add=NET_ADMIN --cap-add=NET_RAW \
        "$TEST_IMAGE_NAME"
    sleep 5

    # Verify the new container's rules are in place (implies cleanup worked)
    info "Verifying cleanup container created its own rules..."
    chain_exists nat "${DEFAULT_PREFIX}_NAT" || fail "Cleanup container failed to create NAT chain"
    chain_exists filter "${DEFAULT_PREFIX}_FORWARD" || fail "Cleanup container failed to create FORWARD chain"
    pass "Cleanup container successfully created its rules."

    # Stop the second container and verify final cleanup
    info "Stopping cleanup container..."
    docker stop "$CONTAINER_CLEANUP"
    sleep 2
    ! chain_exists nat "${DEFAULT_PREFIX}_NAT" || fail "Final NAT chain was not cleaned up"
    ! chain_exists filter "${DEFAULT_PREFIX}_FORWARD" || fail "Final FORWARD chain was not cleaned up"
    pass "Final cleanup was successful."
    info "--- Test Finished: Unclean Shutdown ---"
}

# --- Main Runner ---
main() {
    # Initial cleanup to ensure a clean slate
    cleanup_all

    # Build the test image
    info "Building test Docker image..."
    export E2E_TESTING=true
    ./build-docker.sh "$TEST_IMAGE_NAME"
    unset E2E_TESTING

    # Run tests
    test_default_instance
    test_custom_prefix_instance
    test_unclean_shutdown

    # Final cleanup
    cleanup_all

    echo
    pass "All e2e tests completed successfully!"
}

main
