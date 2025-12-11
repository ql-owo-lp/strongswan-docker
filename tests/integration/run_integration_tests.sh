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
    elif [ "$SCENARIO" == "BGP" ]; then
        SERVER_CONF="$(pwd)/tests/integration/server/ipsec.conf"
        CLIENT_CONF="$(pwd)/tests/integration/client/ipsec.conf"
        # FRR Configs
        SERVER_FRR="$(pwd)/tests/integration/server/frr.conf"
        CLIENT_FRR="$(pwd)/tests/integration/client/frr.conf"
    elif [ "$SCENARIO" == "GRE" ]; then
        # Use Policy mode for IPsec (encrypting GRE) or just VTI... 
        # Actually GRE usually rides over Transport mode or VTI. 
        # For simplicity, let's use the policy-based IPsec config but ADD GRE tunnels via env var.
        SERVER_CONF="$(pwd)/tests/integration/server/ipsec.policy.conf"
        CLIENT_CONF="$(pwd)/tests/integration/client/ipsec.policy.conf"
    else
        SERVER_CONF="$(pwd)/tests/integration/server/ipsec.conf"
        CLIENT_CONF="$(pwd)/tests/integration/client/ipsec.conf"
    fi

    log "Starting Server Container ($SERVER_NAME)..."
    SERVER_ENV=""
    if [ "$SCENARIO" == "GRE" ]; then
        SERVER_ENV="-e EXTRA_TUNNELS=gre1:gre:172.20.0.10:172.20.0.20"
    fi
    SERVER_FRR_MOUNT=""
    if [ -n "$SERVER_FRR" ]; then
        SERVER_FRR_MOUNT="-v $SERVER_FRR:/etc/frr/frr.conf"
    fi

    docker run -d --name $SERVER_NAME \
        --net $TEST_NET --ip $SERVER_IP \
        --privileged \
        -v "$SERVER_CONF:/etc/ipsec.conf" \
        $SERVER_FRR_MOUNT \
        -v "$(pwd)/tests/integration/server/ipsec.secrets:/etc/ipsec.secrets" \
        -v "$(pwd)/docker/entrypoint.sh:/entrypoint.sh" \
        -e OUT_INTERFACE=eth0 \
        $SERVER_ENV \
        --entrypoint tail \
        $IMAGE_NAME -f /dev/null

    log "Configuring Secondary IP on Server..."
    docker exec $SERVER_NAME ip addr add 172.20.0.11/32 dev eth0
    docker exec $SERVER_NAME ip addr show
    
    log "Starting Strongswan on Server..."
    docker exec -d $SERVER_NAME /entrypoint.sh

    log "Starting Client Container ($CLIENT_NAME)..."
    CLIENT_ENV=""
    if [ "$SCENARIO" == "GRE" ]; then
        CLIENT_ENV="-e EXTRA_TUNNELS=gre1:gre:172.20.0.20:172.20.0.10"
    fi
    CLIENT_FRR_MOUNT=""
    if [ -n "$CLIENT_FRR" ]; then
        CLIENT_FRR_MOUNT="-v $CLIENT_FRR:/etc/frr/frr.conf"
    fi

    docker run -d --name $CLIENT_NAME \
        --net $TEST_NET --ip $CLIENT_IP \
        --privileged \
        -v "$CLIENT_CONF:/etc/ipsec.conf" \
        $CLIENT_FRR_MOUNT \
        -v "$(pwd)/tests/integration/client/ipsec.secrets:/etc/ipsec.secrets" \
        -v "$(pwd)/docker/entrypoint.sh:/entrypoint.sh" \
        -e OUT_INTERFACE=eth0 \
        $CLIENT_ENV \
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
         log "TCP iperf3 Test PASSED!"
    else
         error "TCP iperf3 Test FAILED!"
         return 1
    fi

    log "Testing UDP (iperf3)..."
    if docker exec $CLIENT_NAME iperf3 -c 10.10.0.1 -B 192.168.0.1 -u -b 10M -t 5; then
         log "UDP iperf3 Test PASSED!"
    else
         error "UDP iperf3 Test FAILED!"
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

test_hard_recovery() {
    log "Testing Hard Recovery (Killing Client with SIGKILL)..."
    docker kill $CLIENT_NAME
    
    log "Waiting 2s..."
    sleep 2
    
    log "Starting Client again..."
    docker start $CLIENT_NAME
    
    log "Waiting for Client to recover..."
    sleep 5
    
    # Re-apply dummy IP (lost on restart)
    docker exec $CLIENT_NAME ip addr add 192.168.0.1/32 dev eth0
    
    wait_for_connection $CLIENT_NAME "net-1"
    
    log "Retesting connectivity after hard kill..."
    if docker exec $CLIENT_NAME iperf3 -c 10.10.0.1 -B 192.168.0.1 -t 5; then
        log "Hard Recovery Test PASSED!"
    else
        error "Hard Recovery Test FAILED!"
        return 1
    fi
}

test_bgp() {
    log "Testing BGP Session Establishment..."
    
    # Wait for BGP to establish
    local established=false
    for i in $(seq 1 30); do
        if docker exec $CLIENT_NAME vtysh -c "show ip bgp summary" | grep -q "Established"; then
            log "BGP Session ESTABLISHED (Client side)!"
            established=true
            break
        fi
        sleep 2
    done
    
    if [ "$established" != "true" ]; then
        error "BGP Session failed to establish."
        docker exec $CLIENT_NAME vtysh -c "show ip bgp summary"
        return 1
    fi
    
    log "Verifying BGP Routes..."
    sleep 5
    
    # Client should learn 10.10.0.0/16 from Server
    if docker exec $CLIENT_NAME ip route | grep -q "10.10.0.0/16 proto bgp"; then
        log "Client learned Server subnet (10.10.0.0/16) via BGP!"
    else
        error "Client failed to learn Server subnet via BGP."
        docker exec $CLIENT_NAME ip route
        return 1
    fi
    
    # Server should learn 192.168.0.0/16 from Client
    if docker exec $SERVER_NAME ip route | grep -q "192.168.0.0/16 proto bgp"; then
        log "Server learned Client subnet (192.168.0.0/16) via BGP!"
    else
        error "Server failed to learn Client subnet via BGP."
        docker exec $SERVER_NAME ip route
        return 1
    fi
    
    log "BGP Test PASSED!"
}

# --- Main ---
setup

if [ "$SCENARIO" == "POLICY" ]; then
    wait_for_connection $CLIENT_NAME "net-policy"
    test_connectivity
    # Policy test has only one connection currently
elif [ "$SCENARIO" == "BGP" ]; then
    wait_for_connection $CLIENT_NAME "net-1"
    
    # Enable dummy interfaces for BGP to advertise
    log "Adding dummy interface to Client for BGP advertisement..."
    docker exec $CLIENT_NAME ip addr add 192.168.0.1/32 dev eth0 || true
    log "Adding dummy interface to Server for BGP advertisement..."
    docker exec $SERVER_NAME ip addr add 10.10.0.1/32 dev eth0 || true
    
    test_bgp
elif [ "$SCENARIO" == "GRE" ]; then
    wait_for_connection $CLIENT_NAME "net-policy"
    
    log "Testing GRE Tunnel..."
    # Assign IPs to GRE interfaces
    log "Assigning IPs to GRE interfaces..."
    docker exec $SERVER_NAME ip addr add 10.200.0.1/30 dev gre1
    docker exec $SERVER_NAME ip link set gre1 up
    docker exec $CLIENT_NAME ip addr add 10.200.0.2/30 dev gre1
    docker exec $CLIENT_NAME ip link set gre1 up
    
    log "Pinging over GRE..."
    if docker exec $CLIENT_NAME ping -c 3 10.200.0.1; then
        log "GRE Ping PASSED!"
    else
        error "GRE Ping FAILED!"
        return 1
    fi
else
    wait_for_connection $CLIENT_NAME "net-1"
    wait_for_connection $CLIENT_NAME "net-2"
    test_connectivity
    test_redundancy
    test_recovery
    test_hard_recovery
fi

log "ALL TESTS PASSED."
