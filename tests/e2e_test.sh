#!/bin/bash
set -e

# --- Test Configuration ---
IMAGE_NAME="strongswan-e2e-test"
CONTAINER_NAME="strongswan-e2e-container"
CHAIN_PREFIX="E2E_TEST"
CHAIN_NAT="${CHAIN_PREFIX}_NAT"
CHAIN_FORWARD="${CHAIN_PREFIX}_FORWARD"
LOG_FILE="/tmp/e2e_test.log"

# --- Helper Functions ---
cleanup() {
  echo "--- Cleaning up ---"
  # Stop and remove the container if it exists
  if [ "$(docker ps -a -q -f name=${CONTAINER_NAME})" ]; then
    echo "Stopping and removing container: ${CONTAINER_NAME}"
    docker stop ${CONTAINER_NAME} >/dev/null
    docker rm ${CONTAINER_NAME} >/dev/null
  fi

  # Clean up iptables chains and rules
  echo "Cleaning up iptables..."
  iptables -t nat -D POSTROUTING -j ${CHAIN_NAT} 2>/dev/null || true
  iptables -D FORWARD -j ${CHAIN_FORWARD} 2>/dev/null || true
  iptables -t nat -F ${CHAIN_NAT} 2>/dev/null || true
  iptables -t nat -X ${CHAIN_NAT} 2>/dev/null || true
  iptables -F ${CHAIN_FORWARD} 2>/dev/null || true
  iptables -X ${CHAIN_FORWARD} 2>/dev/null || true

  # Remove the built Docker image
  if [ "$(docker images -q ${IMAGE_NAME})" ]; then
    echo "Removing Docker image: ${IMAGE_NAME}"
    docker rmi ${IMAGE_NAME} >/dev/null
  fi
  echo "Cleanup complete."
}

# --- Main Test Logic ---
trap cleanup EXIT

echo "--- Starting E2E Test ---"

# Ensure the iptable_filter module is loaded on the host, as it may be missing in some CI environments
echo "Loading iptable_filter module..."
sudo /sbin/modprobe iptable_filter || true

# 1. Build the Docker image
echo "Building Docker image: ${IMAGE_NAME}"
docker build -t ${IMAGE_NAME} ./docker

# 2. Run the container with the custom chain prefix
echo "Running container: ${CONTAINER_NAME}"
docker run -d --name ${CONTAINER_NAME} \
  --privileged \
  -e IPTABLES_CHAIN_PREFIX=${CHAIN_PREFIX} \
  ${IMAGE_NAME} > ${LOG_FILE} 2>&1

# Give the container a moment to initialize
sleep 5

# 3. Verify iptables rules and chains
echo "Verifying iptables rules..."
if ! iptables -t nat -C POSTROUTING -j ${CHAIN_NAT} >/dev/null 2>&1; then
  echo "FAIL: NAT jump rule not found!"
  docker logs ${CONTAINER_NAME}
  exit 1
fi
if ! iptables -C FORWARD -j ${CHAIN_FORWARD} >/dev/null 2>&1; then
  echo "FAIL: Forward jump rule not found!"
  exit 1
fi
if ! iptables -t nat -L ${CHAIN_NAT} >/dev/null 2>&1; then
  echo "FAIL: NAT chain ${CHAIN_NAT} does not exist!"
  exit 1
fi
if ! iptables -L ${CHAIN_FORWARD} >/dev/null 2>&1; then
  echo "FAIL: Forward chain ${CHAIN_FORWARD} does not exist!"
  exit 1
fi
echo "iptables rules verified successfully."

# 4. Verify strongSwan is running
echo "Verifying strongSwan service..."
if ! docker exec ${CONTAINER_NAME} ipsec status | grep "charon is running"; then
  echo "FAIL: strongSwan (charon) is not running!"
  exit 1
fi
echo "strongSwan service is running."

# 5. Stop the container and verify cleanup
echo "Stopping container and verifying cleanup..."
docker stop ${CONTAINER_NAME}

# Verify the jump rules are gone
if iptables -t nat -C POSTROUTING -j ${CHAIN_NAT} >/dev/null 2>&1; then
  echo "FAIL: NAT jump rule was not removed on container stop!"
  exit 1
fi
if iptables -C FORWARD -j ${CHAIN_FORWARD} >/dev/null 2>&1; then
  echo "FAIL: Forward jump rule was not removed on container stop!"
  exit 1
fi
echo "iptables cleanup verified successfully."

echo "--- E2E Test Passed ---"
exit 0
