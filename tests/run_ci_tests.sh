#!/bin/bash
set -e

# --- Test Configuration ---
IMAGE_NAME="strongswan-ci-test"
CONTAINER_NAME="strongswan-ci-container"
CHAIN_PREFIX="CI_TEST"
CHAIN_NAT="${CHAIN_PREFIX}_NAT"
CHAIN_FORWARD="${CHAIN_PREFIX}_FORWARD"
IPTABLES_MOCK_LOG="tests/iptables_mock.log"

# --- Helper Functions ---
cleanup() {
  echo "--- Cleaning up ---"
  if [ "$(docker ps -a -q -f name=${CONTAINER_NAME})" ]; then
    docker rm -f ${CONTAINER_NAME} >/dev/null
  fi
  if [ "$(docker images -q ${IMAGE_NAME})" ]; then
    docker rmi ${IMAGE_NAME} >/dev/null
  fi
  rm -f ${IPTABLES_MOCK_LOG}
  echo "Cleanup complete."
}

# --- Main Test Logic ---
trap cleanup EXIT

echo "--- Starting CI Test ---"

# 1. Build the Docker image
echo "Building Docker image: ${IMAGE_NAME}"
docker build -t ${IMAGE_NAME} ./docker

# Make the mock script executable
chmod +x tests/mock_iptables.sh

# Create the mock log file
touch ${IPTABLES_MOCK_LOG}

# 2. Run the container
echo "Running container: ${CONTAINER_NAME}"
docker run --name ${CONTAINER_NAME} \
  -v "$(pwd)/tests/ipsec.test.conf:/etc/ipsec.conf" \
  -v "$(pwd)/tests/mock_iptables.sh:/sbin/iptables" \
  -v "$(pwd)/${IPTABLES_MOCK_LOG}:/tests/iptables_mock.log" \
  -e IPTABLES_CHAIN_PREFIX=${CHAIN_PREFIX} \
  -e IPTABLES_MOCK_LOG="/tests/iptables_mock.log" \
  ${IMAGE_NAME}

# 3. Verify iptables commands
echo "Verifying iptables commands..."
# Subnet 1 should be present
if ! grep -q "iptables -A ${CHAIN_FORWARD} -s 10.10.1.0/24 -d 192.168.0.0/16 -j ACCEPT" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Forwarding rule for 10.10.1.0/24 not found!"
  exit 1
fi
# Subnet 2 should be present
if ! grep -q "iptables -A ${CHAIN_FORWARD} -s 10.10.2.0/24 -d 192.168.0.0/16 -j ACCEPT" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Forwarding rule for 10.10.2.0/24 not found!"
  exit 1
fi
# Verify that the duplicate subnet is only added once
if [ "$(grep -c "iptables -A ${CHAIN_FORWARD} -s 10.10.1.0/24" ${IPTABLES_MOCK_LOG})" -ne 1 ]; then
  echo "FAIL: Duplicate rule found for 10.10.1.0/24!"
  exit 1
fi

echo "iptables commands verified successfully."

echo "--- CI Test Passed ---"
exit 0
