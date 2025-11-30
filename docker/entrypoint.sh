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

# --- CRITICAL FIX 1: Enable IP Forwarding ---
echo "Enabling IP Forwarding..."
sysctl -w net.ipv4.ip_forward=1 || echo "Warning: Could not set ip_forward (container might lack privileges)"

LOG_FILE="/var/log/strongswan.log"

# --- Dynamic Configuration Parsing ---

# 1. Detect Routing Table from strongswan.conf
# We grep for 'routing_table', remove spaces, and extract the value. Default to 220.
echo "Detecting routing table from /etc/strongswan.conf..."
if [ -f /etc/strongswan.conf ]; then
    TABLE_NUM=$(grep "routing_table" /etc/strongswan.conf | grep -v "#" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ;')
fi
# Default to 220 if not found or empty
TABLE_NUM=${TABLE_NUM:-220}
echo "Using Routing Table: ${TABLE_NUM}"


# 2. Parse ipsec.conf to discover subnets
AWK_SCRIPT='
    function process_conn() {
        if (in_conn && auto && left && right) {
            print left ";" right;
        }
        in_conn = 0; left = ""; right = ""; auto = 0;
    }
    # Ignore comments
    /^[ \t]*#/ {next}
    # Clean up the line
    {
        # Remove comments
        sub(/#.*/, "");
        # Remove leading/trailing whitespace
        gsub(/^[ \t]+|[ \t]+$/, "");
        # Remove whitespace around =
        gsub(/[ \t]*=[ \t]*/, "=");
    }
    # Skip empty lines
    /^[ \t]*$/ {next}
    /conn %default/ {next}
    /conn/ { process_conn(); in_conn = 1; }
    in_conn && /auto=start/ { auto = 1; }
    in_conn && /leftsubnet=/ { match($0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+/); left=substr($0, RSTART, RLENGTH) }
    in_conn && /rightsubnet=/ { match($0, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+/); right=substr($0, RSTART, RLENGTH) }
    END { process_conn(); }
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

# --- DYNAMIC MSS CALCULATION ---
if [ -r "/sys/class/net/$OUT_INTERFACE/mtu" ]; then
  DETECTED_MTU=$(cat "/sys/class/net/$OUT_INTERFACE/mtu")
else
  # Fallback using ip command if sysfs is not accessible
  DETECTED_MTU=$(ip link show "$OUT_INTERFACE" | awk '/mtu/ {print $5}')
fi

if [ -z "$DETECTED_MTU" ] || [ "$DETECTED_MTU" -eq 0 ]; then
  echo "Warning: Could not detect MTU for $OUT_INTERFACE. Defaulting to 1500."
  DETECTED_MTU=1500
fi

# --- CRITICAL FIX FOR JUMBO FRAMES ---
# Even if local MTU is 9000, internet is usually 1500.
INTERNET_MTU=$DETECTED_MTU
if [ "$INTERNET_MTU" -gt 1500 ]; then
   echo "Detected Jumbo Frames (MTU $INTERNET_MTU). Capping at 1500 for Internet compatibility."
   INTERNET_MTU=1500
fi

# --- ROUTE MTU CALCULATION (THE FIX) ---
# We cannot set the VPN route to 1500, because 1500 plaintext + 80 overhead = 1580 encrypted.
# 1580 will be dropped by the Internet Gateway.
# We must reserve space for IPsec headers IN THE ROUTE ITSELF.
# 1500 - 100 bytes (Overhead + Safety) = 1400.
ROUTE_MTU=$((INTERNET_MTU - 100))

# MSS Calculation: Route MTU - 40 bytes (IP+TCP headers)
# 1400 - 40 = 1360.
MSS_VALUE=$((ROUTE_MTU - 40))

echo "Calculated Safe VPN Parameters:"
echo "  Physical MTU: $DETECTED_MTU"
echo "  Internet Ceiling: $INTERNET_MTU"
echo "  VPN Route MTU: $ROUTE_MTU (Internet - 100 overhead)"
echo "  TCP MSS: $MSS_VALUE (Route MTU - 40)"

# Allow overriding the iptables chain prefix to avoid conflicts
CHAIN_PREFIX="${IPTABLES_CHAIN_PREFIX:-STRONGSWAN}"
CHAIN_NAT="${CHAIN_PREFIX}_NAT"
CHAIN_FORWARD="${CHAIN_PREFIX}_FORWARD"
CHAIN_MANGLE="${CHAIN_PREFIX}_MANGLE"

create_chains() {
  echo "Creating dedicated iptables chains..."
  iptables -t nat -N ${CHAIN_NAT} 2>/dev/null || true
  iptables -N ${CHAIN_FORWARD} 2>/dev/null || true
  iptables -t mangle -N ${CHAIN_MANGLE} 2>/dev/null || true
  echo "Chains created."
}

IPTABLES_RULES=()
MANGLE_RULES=()

for vpn_subnet in "${VPN_SUBNETS[@]}"; do
  echo "Generating rules for VPN subnet: ${vpn_subnet}"
  IPTABLES_RULES+=(
    "-t nat -A ${CHAIN_NAT} -d ${vpn_subnet} -j ACCEPT"
    "-t nat -A ${CHAIN_NAT} -s ${vpn_subnet} -o ${OUT_INTERFACE} -j MASQUERADE"
    "-A ${CHAIN_FORWARD} -s ${vpn_subnet} -d ${LOCAL_NET} -j ACCEPT"
    "-A ${CHAIN_FORWARD} -s ${LOCAL_NET} -d ${vpn_subnet} -j ACCEPT"
  )
  
  # --- MSS CLAMPING ---
  # We clamp outbound SYN packets to force the REMOTE side to send small packets to us.
  MANGLE_RULES+=(
    "-t mangle -A ${CHAIN_MANGLE} -d ${vpn_subnet} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${MSS_VALUE}"
  )
done

IPTABLES_RULES+=(
  "-A ${CHAIN_FORWARD} -m state --state RELATED,ESTABLISHED -j ACCEPT"
)

add_firewall_rules() {
  echo "Adding firewall rules..."
  # Link the custom chains to the main chains
  iptables -t nat -I POSTROUTING 1 -j ${CHAIN_NAT} 2>/dev/null || true
  iptables -I FORWARD 1 -j ${CHAIN_FORWARD} 2>/dev/null || true
  
  # Apply MANGLE to FORWARD and OUTPUT only.
  iptables -t mangle -I FORWARD 1 -j ${CHAIN_MANGLE} 2>/dev/null || true
  iptables -t mangle -I OUTPUT 1 -j ${CHAIN_MANGLE} 2>/dev/null || true

  for rule in "${IPTABLES_RULES[@]}" "${MANGLE_RULES[@]}"; do
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
  iptables -t nat -D POSTROUTING -j ${CHAIN_NAT} 2>/dev/null || true
  iptables -D FORWARD -j ${CHAIN_FORWARD} 2>/dev/null || true
  
  iptables -t mangle -D INPUT -j ${CHAIN_MANGLE} 2>/dev/null || true
  iptables -t mangle -D FORWARD -j ${CHAIN_MANGLE} 2>/dev/null || true
  iptables -t mangle -D OUTPUT -j ${CHAIN_MANGLE} 2>/dev/null || true

  iptables -t nat -F ${CHAIN_NAT} 2>/dev/null || true
  iptables -t nat -X ${CHAIN_NAT} 2>/dev/null || true
  iptables -F ${CHAIN_FORWARD} 2>/dev/null || true
  iptables -X ${CHAIN_FORWARD} 2>/dev/null || true
  iptables -t mangle -F ${CHAIN_MANGLE} 2>/dev/null || true
  iptables -t mangle -X ${CHAIN_MANGLE} 2>/dev/null || true
  echo "Firewall cleanup complete."
}

# --- NEW: Route Monitor ---
# This background function watches the detected table (TABLE_NUM).
# If it sees a route with MTU > ROUTE_MTU, it caps it.
monitor_routes() {
  echo "Starting Route Monitor for Table ${TABLE_NUM} (Target MTU: $ROUTE_MTU)..."
  while true; do
    # Find routes in the table that do NOT have the correct MTU setting
    # We filter for routes going to our VPN subnets
    for subnet in "${VPN_SUBNETS[@]}"; do
        # Check if route exists
        if ip route show table "${TABLE_NUM}" "$subnet" >/dev/null 2>&1; then
            # Check if it already has the mtu parameter set correctly
            CURRENT_ROUTE=$(ip route show table "${TABLE_NUM}" "$subnet")
            if [[ "$CURRENT_ROUTE" != *"mtu $ROUTE_MTU"* ]]; then
                 echo "Fixing MTU for route: $subnet in table ${TABLE_NUM}"
                 # We use 'change' to preserve other attributes like src/via
                 ip route change table "${TABLE_NUM}" $CURRENT_ROUTE mtu $ROUTE_MTU || true
            fi
        fi
    done
    sleep 5
  done
}

# --- Main Execution ---
if [ -n "$IPTABLES_MOCK_LOG" ]; then
  cleanup_firewall
  create_chains
  add_firewall_rules
  exit 0
fi

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

# Start the route monitor in background
monitor_routes &
MONITOR_PID=$!

echo "Initialization complete. Container is running and will stay alive."

tail -f "$LOG_FILE" &

wait "$IPSEC_PID"
