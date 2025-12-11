#!/bin/bash
set -e

# --- Configuration ---
TEST_NET="strongswan-test-net"
SERVER_NAME="strongswan-server"
CLIENT_NAME="strongswan-client"
IMAGE_NAME="ghcr.io/ql-owo-lp/strongswan-docker:latest"
SERVER_IP="172.20.0.10"
CLIENT_IP="172.20.0.20"
TIMEOUT=60

# Subnets
# Server Side: 10.10.0.0/16
# Client Side: 192.168.0.0/16

# --- Colors ---
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[TEST] $1${NC}"; }
error() { echo -e "${RED}[ERROR] $1${NC}"; }

# --- Cleanup ---
cleanup() {
    log "Cleaning up..."
    # Print logs for debugging
    log "--- Server Logs ---"
    docker logs $SERVER_NAME 2>&1 || true
    log "--- Client Logs ---"
    docker logs $CLIENT_NAME 2>&1 || true
    
    docker rm -f $SERVER_NAME $CLIENT_NAME >/dev/null 2>&1 || true
    docker network rm $TEST_NET >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- CLI Argument Parsing ---
SCENARIO="${1:-VTI}" # Default to VTI

log "Running Scenario: $SCENARIO"

# --- Setup ---
setup() {
    log "Building Docker image..."
    # Build locally for testing (skip push)
    docker build -t $IMAGE_NAME ./docker

    log "Creating Docker Network ($TEST_NET)..."
    docker network create --subnet=172.20.0.0/16 $TEST_NET >/dev/null 2>&1 || true

    # Select Configs based on Scenario
    if [ "$SCENARIO" == "POLICY" ]; then
        SERVER_CONF="$(pwd)/tests/integration/server/ipsec.policy.conf"
        CLIENT_CONF="$(pwd)/tests/integration/client/ipsec.policy.conf"
    else
        SERVER_CONF="$(pwd)/tests/integration/server/ipsec.conf"
        CLIENT_CONF="$(pwd)/tests/integration/client/ipsec.conf"
    fi

    log "Starting Server Container ($SERVER_NAME)..."
    docker run -d --name $SERVER_NAME \
        --net $TEST_NET --ip $SERVER_IP \
        --privileged \
        -v "$SERVER_CONF:/etc/ipsec.conf" \
        -v "$(pwd)/tests/integration/server/ipsec.secrets:/etc/ipsec.secrets" \
        -v "$(pwd)/docker/entrypoint.sh:/entrypoint.sh" \
        -e OUT_INTERFACE=eth0 \
        --entrypoint tail \
        $IMAGE_NAME -f /dev/null

    log "Configuring Secondary IP on Server..."
    docker exec $SERVER_NAME ip addr add 172.20.0.11/32 dev eth0
    docker exec $SERVER_NAME ip addr show
    
    log "Starting Strongswan on Server..."
    docker exec -d $SERVER_NAME /entrypoint.sh

    log "Starting Client Container ($CLIENT_NAME)..."
    docker run -d --name $CLIENT_NAME \
        --net $TEST_NET --ip $CLIENT_IP \
        --privileged \
        -v "$CLIENT_CONF:/etc/ipsec.conf" \
        -v "$(pwd)/tests/integration/client/ipsec.secrets:/etc/ipsec.secrets" \
        -v "$(pwd)/docker/entrypoint.sh:/entrypoint.sh" \
        -e OUT_INTERFACE=eth0 \
        $IMAGE_NAME

    log "Installing iperf3..."
    docker exec $SERVER_NAME apk add --no-cache iperf3
    docker exec $CLIENT_NAME apk add --no-cache iperf3
}

wait_for_connection() {
    local container=$1
    local conn_name=$2
    log "Waiting for connection $conn_name on $container..."
    for i in $(seq 1 $TIMEOUT); do
        if docker exec $container ipsec status $conn_name | grep -q "ESTABLISHED"; then
            log "Connection $conn_name ESTABLISHED!"
            return 0
        fi
        sleep 1
    done
    error "Connection $conn_name failed to establish."
    return 1
}

test_connectivity() {
    log "Testing Connectivity (Ping)..."
    
    log "Adding dummy interface to Client matching leftsubnet..."
    docker exec $CLIENT_NAME ip addr add 192.168.0.1/32 dev eth0 || true
    
    log "Adding dummy interface to Server matching rightsubnet..."
    docker exec $SERVER_NAME ip addr add 10.10.0.1/32 dev eth0 || true

    log "Dumping Routes and Interfaces for debugging..."
    log "--- Client Routes ---"
    docker exec $CLIENT_NAME ip route
    log "--- Server Routes ---"
    docker exec $SERVER_NAME ip route
    
    log "Running Ping client -> server..."
    if docker exec $CLIENT_NAME ping -c 3 -W 1 -I 192.168.0.1 10.10.0.1; then
        log "Ping Test PASSED!"
    else
        error "Ping Test FAILED!"
        return 1
    fi
    
    log "Testing TCP (iperf3)..."
    # Start iperf3 server on Server
    docker exec -d $SERVER_NAME iperf3 -s
    sleep 2
    if docker exec $CLIENT_NAME iperf3 -c 10.10.0.1 -B 192.168.0.1 -t 5; then
         log "iperf3 Test PASSED!"
    else
         error "iperf3 Test FAILED!"
         return 1
    fi
}

test_redundancy() {
    log "Testing Redundancy / Second Tunnel..."
    wait_for_connection $CLIENT_NAME "net-2"
    # Same Connectivity test should work
    docker exec $CLIENT_NAME ping -c 3 -W 1 -I 192.168.0.1 10.10.0.1
}

test_recovery() {
    log "Testing Recovery (Restarting Client)..."
    docker restart $CLIENT_NAME
    
    log "Waiting for Client to recover..."
    sleep 5
    
    # Re-apply dummy IP (lost on restart)
    docker exec $CLIENT_NAME ip addr add 192.168.0.1/32 dev eth0
    
    wait_for_connection $CLIENT_NAME "net-1"
    
    log "Retesting connectivity after restart..."
    if docker exec $CLIENT_NAME iperf3 -c 10.10.0.1 -B 192.168.0.1 -t 5; then
        log "Recovery Test PASSED!"
    else
        error "Recovery Test FAILED!"
        return 1
    fi
}

# --- Main ---
setup

if [ "$SCENARIO" == "POLICY" ]; then
    wait_for_connection $CLIENT_NAME "net-policy"
    test_connectivity
    # Policy test has only one connection currently
else
    wait_for_connection $CLIENT_NAME "net-1"
    wait_for_connection $CLIENT_NAME "net-2"
    test_connectivity
    test_redundancy
    test_recovery
fi

log "ALL TESTS PASSED."
