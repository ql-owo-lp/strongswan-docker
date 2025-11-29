#!/bin/bash
set -e

# --- Test Configuration ---
IMAGE_NAME="strongswan-test"
CONTAINER_NAME="strongswan-test-container"
CHAIN_PREFIX="STRONGSWAN_TEST"
CHAIN_NAT="${CHAIN_PREFIX}_NAT"
CHAIN_FORWARD="${CHAIN_PREFIX}_FORWARD"
CHAIN_MANGLE="${CHAIN_PREFIX}_MANGLE"
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

echo "--- Starting Full Test Suite ---"

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

# --- Chain Management Checks ---
echo "Verifying chain management..."
# NAT
if ! grep -q "iptables -t nat -N ${CHAIN_NAT}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Create command for NAT chain not found!"
  exit 1
fi
if ! grep -q "iptables -t nat -I POSTROUTING 1 -j ${CHAIN_NAT}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Create command for NAT jump rule not found!"
  exit 1
fi
if ! grep -q "iptables -t nat -D POSTROUTING -j ${CHAIN_NAT}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Cleanup command for NAT jump rule not found!"
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
# FORWARD
if ! grep -q "iptables -N ${CHAIN_FORWARD}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Create command for Forward chain not found!"
  exit 1
fi
if ! grep -q "iptables -I FORWARD 1 -j ${CHAIN_FORWARD}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Create command for Forward jump rule not found!"
  exit 1
fi
if ! grep -q "iptables -D FORWARD -j ${CHAIN_FORWARD}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Cleanup command for Forward jump rule not found!"
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
# MANGLE
if ! grep -q "iptables -t mangle -N ${CHAIN_MANGLE}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Create command for Mangle chain not found!"
  exit 1
fi
if ! grep -q "iptables -t mangle -I FORWARD 1 -j ${CHAIN_MANGLE}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Create command for Mangle FORWARD jump rule not found!"
  exit 1
fi
if ! grep -q "iptables -t mangle -I OUTPUT 1 -j ${CHAIN_MANGLE}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Create command for Mangle OUTPUT jump rule not found!"
  exit 1
fi
if ! grep -q "iptables -t mangle -D FORWARD -j ${CHAIN_MANGLE}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Cleanup command for Mangle FORWARD jump rule not found!"
  exit 1
fi
if ! grep -q "iptables -t mangle -D OUTPUT -j ${CHAIN_MANGLE}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Cleanup command for Mangle OUTPUT jump rule not found!"
  exit 1
fi
if ! grep -q "iptables -t mangle -F ${CHAIN_MANGLE}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Cleanup command for flushing Mangle chain not found!"
  exit 1
fi
if ! grep -q "iptables -t mangle -X ${CHAIN_MANGLE}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Cleanup command for deleting Mangle chain not found!"
  exit 1
fi
echo "Chain management verified."

# --- Dynamic Rule Generation Checks ---
echo "Verifying dynamic rule generation..."
# Subnet 1
if ! grep -q "iptables -A ${CHAIN_FORWARD} -s 10.10.1.0/24 -d 192.168.0.0/16 -j ACCEPT" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Forwarding rule for 10.10.1.0/24 not found!"
  exit 1
fi
# Subnet 2
if ! grep -q "iptables -A ${CHAIN_FORWARD} -s 10.10.2.0/24 -d 192.168.0.0/16 -j ACCEPT" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Forwarding rule for 10.10.2.0/24 not found!"
  exit 1
fi
# Duplicate subnet check
if [ "$(grep -c "iptables -A ${CHAIN_FORWARD} -s 10.10.1.0/24" ${IPTABLES_MOCK_LOG})" -ne 1 ]; then
  echo "FAIL: Duplicate rule found for 10.10.1.0/24!"
  exit 1
fi
# MSS Clamping Rule
if ! grep -q "iptables -t mangle -A ${CHAIN_MANGLE} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: TCPMSS rule for MSS clamping not found!"
  exit 1
fi
echo "Dynamic rule generation verified."

echo "iptables commands verified successfully."
echo "--- Full Test Suite Passed ---"
exit 0
