#!/bin/bash
set -e

# --- Test Configuration ---
IMAGE_NAME="strongswan-test"
CONTAINER_NAME="strongswan-test-container"
CHAIN_PREFIX="STRONGSWAN_TEST"
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

echo "--- Starting Full Test Suite ---"

# 1. Build the Docker image
echo "Building Docker image: ${IMAGE_NAME}"
docker build -t ${IMAGE_NAME} ./docker

# Make the mock scripts executable
chmod +x tests/mock_iptables.sh
chmod +x tests/mock_ip.sh
chmod +x tests/mock_sysctl.sh

# Create the mock log file
touch ${IPTABLES_MOCK_LOG}

# 2. Run the container
echo "Running container: ${CONTAINER_NAME}"
docker run --name ${CONTAINER_NAME} \
  -v "$(pwd)/tests/ipsec.test.conf:/etc/ipsec.conf" \
  -v "$(pwd)/tests/mock_iptables.sh:/sbin/iptables" \
  -v "$(pwd)/tests/mock_ip.sh:/sbin/ip" \
  -v "$(pwd)/tests/mock_sysctl.sh:/sbin/sysctl" \
  -v "$(pwd)/${IPTABLES_MOCK_LOG}:/tests/iptables_mock.log" \
  -e IPTABLES_CHAIN_PREFIX=${CHAIN_PREFIX} \
  -e IPTABLES_MOCK_LOG="/tests/iptables_mock.log" \
  ${IMAGE_NAME}

# 3. Verify iptables and ip commands
echo "Verifying commands..."

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
# FORWARD
if ! grep -q "iptables -N ${CHAIN_FORWARD}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Create command for Forward chain not found!"
  exit 1
fi
if ! grep -q "iptables -I FORWARD 1 -j ${CHAIN_FORWARD}" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Create command for Forward jump rule not found!"
  exit 1
fi

echo "Chain management verified."

# --- Dynamic Rule Generation Checks ---
echo "Verifying dynamic rule generation..."

# --- LEGACY MODE CHECKS ---
# Subnet 1 (vpn-main)
if ! grep -q "iptables -A ${CHAIN_FORWARD} -s 10.10.1.0/24 -j ACCEPT" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Forwarding rule for 10.10.1.0/24 not found!"
  exit 1
fi
if ! grep -q "iptables -t nat -A ${CHAIN_NAT} -d 10.10.1.0/24 -j ACCEPT" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: NAT Accept rule for 10.10.1.0/24 not found!"
  exit 1
fi

# MSS Clamping Rule (Legacy)
if ! grep -q "iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1280" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: TCPMSS rule for legacy mode not found!"
  exit 1
fi

# --- VTI MODE CHECKS ---
echo "Verifying VTI setup..."
# VTI Interface Creation
if ! grep -q 'ip tunnel add strongswanl_v10 mode vti remote 5.6.7.8 key 10' ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: 'ip tunnel add strongswanl_v10' command not found!"
  exit 1
fi
if ! grep -q "ip link set strongswanl_v10 up mtu 1400" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: 'ip link set strongswanl_v10' command not found!"
  exit 1
fi

# Routing
if ! grep -q "ip route add 172.31.0.0/21 dev strongswanl_v10" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: 'ip route add 172.31.0.0/21' command not found!"
  exit 1
fi

# Firewall rules for VTI
# Allow forwarding over VTI
if ! grep -q "iptables -A ${CHAIN_FORWARD} -i strongswanl_v10 -j ACCEPT" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Forwarding rule for input strongswanl_v10 not found!"
  exit 1
fi
if ! grep -q "iptables -A ${CHAIN_FORWARD} -o strongswanl_v10 -j ACCEPT" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: Forwarding rule for output strongswanl_v10 not found!"
  exit 1
fi

# NAT Exemption
if ! grep -q "iptables -t nat -A ${CHAIN_NAT} -d 172.31.0.0/21 -j ACCEPT" ${IPTABLES_MOCK_LOG}; then
  echo "FAIL: NAT Exemption rule for 172.31.0.0/21 not found!"
  exit 1
fi

echo "VTI setup verified."

echo "All commands verified successfully."
echo "--- Full Test Suite Passed ---"
exit 0
