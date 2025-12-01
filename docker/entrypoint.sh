#!/bin/bash
set -e

# --- Diagnostic Logging ---
echo "--- Initializing strongSwan Container (VTI Enabled) ---"
echo "Detecting iptables version..."
echo "iptables binary: $(command -v iptables || echo 'Not found')"
iptables --version
echo "-----------------------------------------"

# --- CRITICAL: Enable IP Forwarding ---
echo "Enabling IP Forwarding..."
sysctl -w net.ipv4.ip_forward=1 || echo "Warning: Could not set ip_forward"

LOG_FILE="/var/log/strongswan.log"

# --- CONFIGURATION PARSER ---
# This script extracts connections and their VTI parameters (mark, left, right, subnets)
# Format output: CONN_NAME;MARK;LEFT_IP;RIGHT_IP;LOCAL_SUBNETS;REMOTE_SUBNETS
AWK_SCRIPT='
    function process_conn() {
        if (in_conn && auto && left && right) {
            # Default mark to 0 if not set
            if (mark == "") mark="0";
            print name ";" mark ";" left ";" right ";" left_sub ";" right_sub;
        }
        in_conn = 0; name=""; mark=""; left=""; right=""; left_sub=""; right_sub=""; auto=0;
    }
    # Clean up line: remove comments, trim whitespace, compact "=", remove CR
    { sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); gsub(/[ \t]*=[ \t]*/, "="); gsub(/\r/, ""); }

    # Skip empty lines
    /^[ \t]*$/ {next}

    # Skip default section
    /conn %default/ {next}

    # Start of a new connection
    /^conn / { process_conn(); in_conn=1; name=$2; }

    # Parse parameters (splitting by "=")
    in_conn && /^auto=start/ { auto=1; }
    in_conn && /^mark=/ { split($0, a, "="); mark=a[2]; }
    in_conn && /^left=/ { split($0, a, "="); left=a[2]; }
    in_conn && /^right=/ { split($0, a, "="); right=a[2]; }
    in_conn && /^leftsubnet=/ { split($0, a, "="); left_sub=a[2]; }
    in_conn && /^rightsubnet=/ { split($0, a, "="); right_sub=a[2]; }

    END { process_conn(); }
'

# Read configs from ipsec.conf
# Note: This looks specifically at /etc/ipsec.conf.
# If your connections are defined inside strongswan.conf, they will be missed
# unless you move them to ipsec.conf (the standard location).
echo "DEBUG: Reading /etc/ipsec.conf:"
cat /etc/ipsec.conf
echo "DEBUG: End of /etc/ipsec.conf"

# Use gawk if available, otherwise awk
AWK_BIN="awk"
if command -v gawk >/dev/null; then
    AWK_BIN="gawk"
fi
echo "Using AWK: $AWK_BIN"

CONFIG_DATA=$($AWK_BIN "$AWK_SCRIPT" /etc/ipsec.conf)
echo "DEBUG: Parsed Configuration:"
echo "$CONFIG_DATA"
echo "DEBUG: End Configuration"

# Detect Interface
if [ -z "$OUT_INTERFACE" ]; then
  OUT_INTERFACE=$(ip route | grep default | $AWK_BIN '{print $5}')
fi
echo "Physical Interface: $OUT_INTERFACE"

# --- FIREWALL & VTI SETUP ---
CHAIN_PREFIX="${IPTABLES_CHAIN_PREFIX:-STRONGSWAN}"
CHAIN_NAT="${CHAIN_PREFIX}_NAT"
CHAIN_FORWARD="${CHAIN_PREFIX}_FORWARD"

create_chains() {
  iptables -t nat -N ${CHAIN_NAT} 2>/dev/null || true
  iptables -N ${CHAIN_FORWARD} 2>/dev/null || true
}

cleanup_firewall() {
  echo "Cleaning up firewall..."
  iptables -t nat -D POSTROUTING -j ${CHAIN_NAT} 2>/dev/null || true
  iptables -D FORWARD -j ${CHAIN_FORWARD} 2>/dev/null || true
  iptables -t nat -F ${CHAIN_NAT} 2>/dev/null || true
  iptables -t nat -X ${CHAIN_NAT} 2>/dev/null || true
  iptables -F ${CHAIN_FORWARD} 2>/dev/null || true
  iptables -X ${CHAIN_FORWARD} 2>/dev/null || true
}

setup_vti() {
    local mark=$1
    local local_ip=$2
    local remote_ip=$3
    local vti_name="vti${mark}"

    # VTI MTU: 1400 is the "Golden Number".
    # 1400 + IPsec Overhead < 1500 (Internet MTU).
    # This prevents fragmentation/drops on the WAN.
    local vti_mtu=1400

    if ip link show "$vti_name" >/dev/null 2>&1; then
        echo "VTI interface $vti_name already exists, resetting..."
        ip link del "$vti_name"
    fi

    echo "Creating VTI Interface: $vti_name (MTU: $vti_mtu, Mark: $mark)"
    ip tunnel add "$vti_name" mode vti local "$local_ip" remote "$remote_ip" key "$mark"
    ip link set "$vti_name" up mtu "$vti_mtu"

    # Disable policy lookup on the VTI interface itself (prevents loops)
    sysctl -w "net.ipv4.conf.${vti_name}.disable_policy=1" >/dev/null

    # Add routing for remote subnets
    # We parse the comma-separated remote subnets
    IFS=',' read -ra SUBNETS <<< "$4"
    for subnet in "${SUBNETS[@]}"; do
        echo "  -> Routing $subnet via $vti_name"
        ip route add "$subnet" dev "$vti_name"
    done
}

apply_firewall() {
    iptables -t nat -I POSTROUTING 1 -j ${CHAIN_NAT} 2>/dev/null || true
    iptables -I FORWARD 1 -j ${CHAIN_FORWARD} 2>/dev/null || true

    # Accept existing connections
    iptables -A ${CHAIN_FORWARD} -m state --state RELATED,ESTABLISHED -j ACCEPT

    # Parse config to generate rules
    while IFS=';' read -r name mark left right left_sub right_sub; do
        # Skip empty lines
        if [ -z "$name" ]; then continue; fi

        if [ "$mark" != "0" ]; then
            # --- VTI MODE ---
            echo "Configuring VTI Firewall for $name (vti${mark})..."
            setup_vti "$mark" "$left" "$right" "$right_sub"

            # Allow forwarding over VTI
            iptables -A ${CHAIN_FORWARD} -i "vti${mark}" -j ACCEPT
            iptables -A ${CHAIN_FORWARD} -o "vti${mark}" -j ACCEPT

            # NAT Exemption (Critical)
            IFS=',' read -ra R_SUBNETS <<< "$right_sub"
            for subnet in "${R_SUBNETS[@]}"; do
                iptables -t nat -A ${CHAIN_NAT} -d "$subnet" -j ACCEPT
            done
        else
            # --- LEGACY POLICY MODE ---
            echo "Configuring Policy Firewall for $name..."
            # (Keep your basic NAT/Forward logic for non-VTI connections)
            IFS=',' read -ra R_SUBNETS <<< "$right_sub"
            for subnet in "${R_SUBNETS[@]}"; do
                 iptables -t nat -A ${CHAIN_NAT} -d "$subnet" -j ACCEPT
                 iptables -t nat -A ${CHAIN_NAT} -s "$subnet" -o "$OUT_INTERFACE" -j MASQUERADE
                 iptables -A ${CHAIN_FORWARD} -s "$subnet" -j ACCEPT
                 iptables -A ${CHAIN_FORWARD} -d "$subnet" -j ACCEPT
            done

            # Basic MSS Clamping fallback for Legacy Mode
            iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360 2>/dev/null || true
        fi
    done <<< "$CONFIG_DATA"
}

# --- Main Execution ---
if [ -n "$IPTABLES_MOCK_LOG" ]; then
    cleanup_firewall
    create_chains
    apply_firewall
    exit 0
fi

trap 'shutdown' TERM INT
shutdown() {
    echo "Shutting down..."
    cleanup_firewall
    # Cleanup VTIs
    ip tunnel show | grep vti | awk -F: '{print $1}' | while read intf; do ip link del $intf; done
    if [ -n "$IPSEC_PID" ]; then kill "$IPSEC_PID"; fi
    exit 0
}

cleanup_firewall
create_chains
apply_firewall

echo "Starting strongSwan..."
ipsec start --nofork > "$LOG_FILE" 2>&1 &
IPSEC_PID=$!

sleep 5

# Start connections
while IFS=';' read -r name mark rest; do
    if [ -z "$name" ]; then continue; fi
    echo "Bringing up connection: $name"
    ipsec up "$name" >/dev/null 2>&1 || true
done <<< "$CONFIG_DATA"

echo "Initialization complete."
tail -f "$LOG_FILE" &
wait "$IPSEC_PID"
