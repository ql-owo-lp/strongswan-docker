#!/bin/bash
set -e

LOG_FILE="/var/log/strongswan.log"

# --- Network Configuration ---
# Set sane defaults for network variables, but allow them to be overridden by environment variables.
LOCAL_NET="${LOCAL_NET:-192.168.0.0/16}"
VPN_SUBNET="${VPN_SUBNET:-10.10.0.0/24}"

# Auto-detect the primary network interface if not provided.
if [ -z "$OUT_INTERFACE" ]; then
  echo "OUT_INTERFACE not set. Detecting default interface..."
  OUT_INTERFACE=$(ip route | grep default | awk '{print $5}')
  if [ -z "$OUT_INTERFACE" ]; then
    echo "Could not detect default interface. Please set OUT_INTERFACE manually."
    exit 1
  fi
  echo "Detected default interface: ${OUT_INTERFACE}"
else
  echo "Using provided OUT_INTERFACE: ${OUT_INTERFACE}"
fi

# Define custom chain names, allowing for a user-specified prefix
# to run multiple instances without rule conflicts.
IPTABLES_CHAIN_PREFIX="${IPTABLES_CHAIN_PREFIX:-STRONGSWAN}"
NAT_CHAIN="${IPTABLES_CHAIN_PREFIX}_NAT"
FORWARD_CHAIN="${IPTABLES_CHAIN_PREFIX}_FORWARD"

cleanup_firewall_rules() {
  echo "Cleaning up existing firewall rules..."

  # Remove jump rule from POSTROUTING if it exists
  if iptables -t nat -C POSTROUTING -j ${NAT_CHAIN} >/dev/null 2>&1; then
    iptables -t nat -D POSTROUTING -j ${NAT_CHAIN}
  fi

  # Remove jump rule from FORWARD if it exists
  if iptables -C FORWARD -j ${FORWARD_CHAIN} >/dev/null 2>&1; then
    iptables -D FORWARD -j ${FORWARD_CHAIN}
  fi

  # Flush and delete the custom NAT chain if it exists
  if iptables -t nat -L ${NAT_CHAIN} >/dev/null 2>&1; then
    iptables -t nat -F ${NAT_CHAIN}
    iptables -t nat -X ${NAT_CHAIN}
  fi

  # Flush and delete the custom FORWARD chain if it exists
  if iptables -L ${FORWARD_CHAIN} >/dev/null 2>&1; then
    iptables -F ${FORWARD_CHAIN}
    iptables -X ${FORWARD_CHAIN}
  fi

  echo "Firewall cleanup complete."
}

add_firewall_rules() {
  # Clean up any old rules first to ensure a fresh start
  cleanup_firewall_rules

  echo "Adding firewall rules..."

  # Create the custom chains
  iptables -t nat -N ${NAT_CHAIN}
  iptables -N ${FORWARD_CHAIN}

  # Add rules to the custom chains
  iptables -t nat -A ${NAT_CHAIN} -d ${VPN_SUBNET} -j ACCEPT
  iptables -t nat -A ${NAT_CHAIN} -s ${VPN_SUBNET} -o ${OUT_INTERFACE} -j MASQUERADE

  iptables -A ${FORWARD_CHAIN} -s ${VPN_SUBNET} -d ${LOCAL_NET} -j ACCEPT
  iptables -A ${FORWARD_CHAIN} -s ${LOCAL_NET} -d ${VPN_SUBNET} -j ACCEPT
  iptables -A ${FORWARD_CHAIN} -m state --state RELATED,ESTABLISHED -j ACCEPT

  # Add jump rules to the main chains
  iptables -t nat -I POSTROUTING 1 -j ${NAT_CHAIN}
  iptables -I FORWARD 1 -j ${FORWARD_CHAIN}

  echo "Firewall rules applied."
}

remove_firewall_rules() {
  # The cleanup function does everything needed for a graceful shutdown too
  cleanup_firewall_rules
}

# Add the firewall rules at startup.
add_firewall_rules
# --- End of Network Configuration ---

shutdown() {
  echo "Shutting down strongSwan..."
  remove_firewall_rules

  if [ -n "$IPSEC_PID" ]; then
    kill "$IPSEC_PID"
  fi
  ipsec stop >> "$LOG_FILE" 2>&1
  exit 0
}

trap 'shutdown' TERM INT

echo "Starting strongSwan daemon in the background..."
ipsec start --nofork > "$LOG_FILE" 2>&1 &
IPSEC_PID=$!

sleep 5

CONN_NAMES=$(awk '
    /conn %default/ {next}
    /conn/ { conn_name = $2; auto_start = 0; }
    /auto=start/ { auto_start = 1; }
    /^$/ { if (!auto_start && conn_name != "") { print conn_name; } conn_name = ""; }
    END { if (!auto_start && conn_name != "") { print conn_name; } }
' /etc/ipsec.conf)

if [ -z "$CONN_NAMES" ]; then
  echo "Warning: No connections found to automatically start."
else
  echo "Found connections to automatically start:"
  for conn in $CONN_NAMES; do
    echo "- $conn"
  done
  echo "---"
  for conn in $CONN_NAMES; do
    echo "--> Attempting to bring up tunnel: $conn"
    ipsec up "$conn"
  done
fi

echo "Initialization complete. Container is running and will stay alive."

tail -f "$LOG_FILE" &

wait "$IPSEC_PID"
