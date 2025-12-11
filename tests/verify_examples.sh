#!/bin/bash
set -e

IMAGE_NAME="ghcr.io/ql-owo-lp/strongswan-docker:latest"
CONTAINER_NAME="strongswan-example-verifier"
EXAMPLES_DIR="$(pwd)/examples"

# Check if examples directory exists
if [ ! -d "$EXAMPLES_DIR" ]; then
    echo "Examples directory not found: $EXAMPLES_DIR"
    exit 1
fi

log() { echo -e "\033[0;32m[VERIFY] $1\033[0m"; }
error() { echo -e "\033[0;31m[ERROR] $1\033[0m"; }

cleanup() {
    docker rm -f $CONTAINER_NAME >/dev/null 2>&1 || true
}
trap cleanup EXIT

verify_config() {
    local config_file=$1
    local config_name=$(basename "$config_file")
    
    # Skip non-ipsec configs
    if [[ "$config_name" == "frr.conf" ]]; then
        return
    fi
    
    log "Verifying configuration: $config_name"
    
    # Create a dummy secrets file if needed
    touch /tmp/dummy.secrets
    
    # Start container
    docker run -d --name $CONTAINER_NAME \
        --privileged \
        -v "$config_file:/etc/ipsec.conf" \
        -v "/tmp/dummy.secrets:/etc/ipsec.secrets" \
        -v "$(pwd)/docker/entrypoint.sh:/entrypoint.sh" \
        -e OUT_INTERFACE=eth0 \
        $IMAGE_NAME >/dev/null
        
    # Wait for initialization
    sleep 5
    
    # Check logs for errors
    if docker logs $CONTAINER_NAME 2>&1 | grep -q "syntax error"; then
        error "Syntax error detected in $config_name"
        docker logs $CONTAINER_NAME
        return 1
    fi
    
    # Check if strongswan started
    if ! docker exec $CONTAINER_NAME ipsec status >/dev/null 2>&1; then
        error "Strongswan failed to start for $config_name"
        docker logs $CONTAINER_NAME
        return 1
    fi
    
    # Specific checks based on config type
    if [[ "$config_name" == *"vti"* ]]; then
        log "Checking for VTI interface..."
        if docker exec $CONTAINER_NAME ip link show | grep -q "vti"; then
            log "VTI interface found."
        else
            error "VTI interface NOT found for $config_name"
            return 1
        fi
    fi
    
    log "Configuration $config_name verified successfully."
    cleanup
}

verify_frr() {
    log "Verifying FRR Configuration (BGP/OSPF)..."
    local config_file="$EXAMPLES_DIR/vti-based.conf"
    local frr_conf="$EXAMPLES_DIR/frr.conf"
    
    touch /tmp/dummy.secrets
    
    docker run -d --name $CONTAINER_NAME \
        --privileged \
        -v "$config_file:/etc/ipsec.conf" \
        -v "$frr_conf:/etc/frr/frr.conf" \
        -v "/tmp/dummy.secrets:/etc/ipsec.secrets" \
        -v "$(pwd)/docker/entrypoint.sh:/entrypoint.sh" \
        -e OUT_INTERFACE=eth0 \
        $IMAGE_NAME >/dev/null
        
    sleep 5
    
    if docker exec $CONTAINER_NAME ps | grep -q "zebra"; then
        log "Zebra is running."
    else
        error "Zebra failed to start."
        docker logs $CONTAINER_NAME
        return 1
    fi
    
    if docker exec $CONTAINER_NAME ps | grep -q "bgpd"; then
        log "BGPd is running."
    else
        error "BGPd failed to start."
        docker logs $CONTAINER_NAME
        return 1
    fi
    
    log "FRR verification passed."
    cleanup
}

# Build image
log "Building image..."
docker build -t $IMAGE_NAME ./docker >/dev/null

# Iterate over examples
for conf in $EXAMPLES_DIR/*.conf; do
    verify_config "$conf"
done

# Verify FRR
verify_frr

log "All examples and FRR verified!"
