#!/bin/bash
set -e

# --- Test Configuration ---
IMAGE_NAME="strongswan-e2e-test"
CONTAINER_NAME="strongswan-e2e-container"
CHAIN_PREFIX="E2E_TEST"
CHAIN_NAT="${CHAIN_PREFIX}_NAT"
CHAIN_FORWARD="${CHAIN_PREFIX}_FORWARD"
LOG_FILE="tests/e2e_test.log"
IPTABLES_MOCK_LOG="tests/iptables_mock.log"

# --- Helper Functions ---
cleanup() {
  echo "--- Cleaning up ---"
  # Stop and remove the container if it exists
  if [ "$(docker ps -a -q -f name=${CONTAINER_NAME})" ]; then
    echo "Stopping and removing container: ${CONTAINER_NAME}"
    docker stop ${CONTAINER_NAME} >/dev/null
    docker rm ${CONTAINER_NAME} >/dev/null
  fi

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

# 1. Build the Docker image
echo "Building Docker image: ${IMAGE_NAME}"
docker build -t ${IMAGE_NAME} ./docker

# Make the mock script executable
chmod +x tests/mock_iptables.sh

# 2. Run the container with the custom chain prefix and mock iptables
echo "Running container: ${CONTAINER_NAME}"
docker run --name ${CONTAINER_NAME} \
  -v "$(pwd)/tests:/tests" \
  -v "$(pwd)/tests/mock_iptables.sh:/sbin/iptables" \
  -e IPTABLES_CHAIN_PREFIX=${CHAIN_PREFIX} \
  -e IPTABLES_MOCK_LOG="/tests/iptables_mock.log" \
  ${IMAGE_NAME} > ${LOG_FILE} 2>&1

# 3. Verify iptables commands
echo "Verifying iptables commands..."
if ! grep -q "iptables -t nat -D POSTROUTING -j ${CHAIN_NAT}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Cleanup command for NAT jump rule not found!"
  exit 1
fi
if ! grep -q "iptables -D FORWARD -j ${CHAIN_FORWARD}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Cleanup command for Forward jump rule not found!"
  exit 1
fi
if ! grep -q "iptables -t nat -F ${CHAIN_NAT}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Cleanup command for flushing NAT chain not found!"
  exit 1
fi
if ! grep -q "iptables -t nat -X ${CHAIN_NAT}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Cleanup command for deleting NAT chain not found!"
  exit 1
fi
if ! grep -q "iptables -F ${CHAIN_FORWARD}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Cleanup command for flushing Forward chain not found!"
  exit 1
fi
if ! grep -q "iptables -X ${CHAIN_FORWARD}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Cleanup command for deleting Forward chain not found!"
  exit 1
fi
if ! grep -q "iptables -t nat -N ${CHAIN_NAT}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Create command for NAT chain not found!"
  exit 1
fi
if ! grep -q "iptables -N ${CHAIN_FORWARD}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Create command for Forward chain not found!"
  exit 1
fi
if ! grep -q "iptables -t nat -I POSTROUTING 1 -j ${CHAIN_NAT}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Create command for NAT jump rule not found!"
  exit 1
fi
if ! grep -q "iptables -I FORWARD 1 -j ${CHAIN_FORWARD}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Create command for Forward jump rule not found!"
  exit 1
fi
echo "iptables commands verified successfully."

echo "--- E2E Test Passed ---"
exit 0
