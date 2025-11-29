#!/bin/bash
set -e

# --- Diagnostic Logging ---
echo "--- Initializing strongSwan Container ---"
echo "Detecting iptables version..."
# Log the path to the iptables executable
echo "iptables binary: $(which iptables)"
# Log the version of iptables, which indicates if it's legacy or nft
iptables --version
echo "-----------------------------------------"

LOG_FILE="/var/log/strongswan.log"

# --- Network Configuration ---
# Parse ipsec.conf to discover the local and remote subnets.
AWK_SCRIPT='
    /conn %default/ {next}
    /conn/ { in_conn = 1; left = ""; right = ""; auto = 0; }
    in_conn && /auto=start/ { auto = 1; }
    in_conn && /leftsubnet=/ { match($0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+/); left=substr($0, RSTART, RLENGTH) }
    in_conn && /rightsubnet=/ { match($0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+/); right=substr($0, RSTART, RLENGTH) }
    /^$/ {
        if (in_conn && auto && left && right) {
            print left ";" right;
        }
        in_conn = 0; left = ""; right = ""; auto = 0;
    }
    END {
        if (in_conn && auto && left && right) {
            print left ";" right;
        }
    }
'
SUBNETS=$(awk "$AWK_SCRIPT" /etc/ipsec.conf)

if [ -z "$SUBNETS" ]; then
  echo "Warning: No connections with 'auto=start', 'leftsubnet', and 'rightsubnet' found in /etc/ipsec.conf."
  echo "Using default LOCAL_NET and VPN_SUBNET. This may not be correct."
  LOCAL_NET="${LOCAL_NET:-192.168.0.0/16}"
  VPN_SUBNET="${VPN_SUBNET:-10.10.0.0/24}"
  VPN_SUBNETS=($VPN_SUBNET)
else
  echo "Found the following subnets in ipsec.conf:"
  echo "$SUBNETS"
  # Use the first leftsubnet as our local network.
  LOCAL_NET=$(echo "$SUBNETS" | head -n 1 | cut -d';' -f1)
  # Use all rightsubnets as our VPN subnets.
  VPN_SUBNETS=($(echo "$SUBNETS" | cut -d';' -f2 | sort -u))
  echo "Inferred LOCAL_NET: ${LOCAL_NET}"
  echo "Inferred VPN_SUBNETS: ${VPN_SUBNETS[*]}"
fi

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

# Allow overriding the iptables chain prefix to avoid conflicts
CHAIN_PREFIX="${IPTABLES_CHAIN_PREFIX:-STRONGSWAN}"
CHAIN_NAT="${CHAIN_PREFIX}_NAT"
CHAIN_FORWARD="${CHAIN_PREFIX}_FORWARD"

create_chains() {
  echo "Creating dedicated iptables chains..."
  # Create NAT chain, ignoring "chain already exists" error
  iptables -t nat -N ${CHAIN_NAT} 2>/dev/null || true
  # Create FORWARD chain, ignoring "chain already exists" error
  iptables -N ${CHAIN_FORWARD} 2>/dev/null || true
  echo "Chains created."
}

# Define the iptables rules that will be added to our custom chains.
IPTABLES_RULES=()

for vpn_subnet in "${VPN_SUBNETS[@]}"; do
  echo "Generating rules for VPN subnet: ${vpn_subnet}"
  IPTABLES_RULES+=(
    # NAT rules for the custom chain
    "-t nat -A ${CHAIN_NAT} -d ${vpn_subnet} -j ACCEPT"
    "-t nat -A ${CHAIN_NAT} -s ${vpn_subnet} -o ${OUT_INTERFACE} -j MASQUERADE"
    # Forwarding rules for the custom chain
    "-A ${CHAIN_FORWARD} -s ${vpn_subnet} -d ${LOCAL_NET} -j ACCEPT"
    "-A ${CHAIN_FORWARD} -s ${LOCAL_NET} -d ${vpn_subnet} -j ACCEPT"
  )
done

# This rule should only be added once.
IPTABLES_RULES+=(
  "-A ${CHAIN_FORWARD} -m state --state RELATED,ESTABLISHED -j ACCEPT"
)

add_firewall_rules() {
  echo "Adding firewall rules..."
  # Link the custom chains to the main chains, ensuring they are at the top.
  iptables -t nat -I POSTROUTING 1 -j ${CHAIN_NAT} 2>/dev/null || true
  iptables -I FORWARD 1 -j ${CHAIN_FORWARD} 2>/dev/null || true

  for rule in "${IPTABLES_RULES[@]}"; do
    check_rule="${rule/-A/-C}"
    if ! iptables ${check_rule} >/dev/null 2>&1; then
      echo "  Adding rule: iptables ${rule}"
      iptables ${rule}
    else
      echo "  Rule already exists: iptables ${rule}"
    fi
  done
  echo "Firewall rules applied."
}

cleanup_firewall() {
  echo "Cleaning up old firewall rules..."
  # Remove the jump rules from the main chains
  iptables -t nat -D POSTROUTING -j ${CHAIN_NAT} 2>/dev/null || true
  iptables -D FORWARD -j ${CHAIN_FORWARD} 2>/dev/null || true

  # Flush and delete the custom chains
  iptables -t nat -F ${CHAIN_NAT} 2>/dev/null || true
  iptables -t nat -X ${CHAIN_NAT} 2>/dev/null || true
  iptables -F ${CHAIN_FORWARD} 2>/dev/null || true
  iptables -X ${CHAIN_FORWARD} 2>/dev/null || true
  echo "Firewall cleanup complete."
}

# --- Main Execution ---
# If we are in a test environment, run the script in the foreground
if [ -n "$IPTABLES_MOCK_LOG" ]; then
  cleanup_firewall
  create_chains
  add_firewall_rules
  exit 0
fi

# Clean up any old rules, create the chains, and add the new rules.
cleanup_firewall
create_chains
add_firewall_rules

shutdown() {
  echo "Shutting down strongSwan..."
  cleanup_firewall

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
