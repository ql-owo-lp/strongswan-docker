#!/bin/bash
set -e

# --- Diagnostic Logging ---
echo "--- Initializing strongSwan Container (VTI & Legacy Dual-Mode) ---"
echo "Detecting iptables version..."
echo "iptables binary: $(command -v iptables || echo 'Not found')"
iptables --version
echo "-----------------------------------------"

# --- CRITICAL: Enable IP Forwarding ---
echo "Enabling IP Forwarding..."
sysctl -w net.ipv4.ip_forward=1 || echo "Warning: Could not set ip_forward"

# --- PERFORMANCE TUNING (CRITICAL FOR 10GbE) ---
echo "Tuning Kernel Network Buffers for High Speed IPsec..."
# Default buffers are often too small for multi-stream 10GbE IPsec, causing stalls on -P > 2
sysctl -w net.core.rmem_default=1048576 || echo "Warning: Failed to set net.core.rmem_default"
sysctl -w net.core.wmem_default=1048576 || echo "Warning: Failed to set net.core.wmem_default"
sysctl -w net.core.rmem_max=16777216 || echo "Warning: Failed to set net.core.rmem_max"
sysctl -w net.core.wmem_max=16777216 || echo "Warning: Failed to set net.core.wmem_max"
sysctl -w net.ipv4.tcp_rmem='4096 87380 16777216' || echo "Warning: Failed to set net.ipv4.tcp_rmem"
sysctl -w net.ipv4.tcp_wmem='4096 87380 16777216' || echo "Warning: Failed to set net.ipv4.tcp_wmem"
sysctl -w net.core.netdev_max_backlog=5000 || echo "Warning: Failed to set net.core.netdev_max_backlog"

LOG_FILE="/var/log/strongswan.log"

# --- DYNAMIC CONFIGURATION PARSING ---

# 1. Detect Routing Table from strongswan.conf
# We grep for 'routing_table', remove spaces, and extract the value. Default to 220.
echo "Detecting routing table from /etc/strongswan.conf..."
if [ -f /etc/strongswan.conf ]; then
    TABLE_NUM=$(grep "routing_table" /etc/strongswan.conf | grep -v "#" | head -n 1 | awk -F'=' '{print $2}' | tr -d ' ;')
fi
# Default to 220 if not found or empty
TABLE_NUM=${TABLE_NUM:-220}
echo "Using Routing Table: ${TABLE_NUM}"

# --- CLEANUP LEFTOVERS ---
FLUSH_POLICY_ON_START=${FLUSH_POLICY_ON_START:-true}
LOAD_BALANCE=${LOAD_BALANCE:-false}
# Use INSTANCE_ID to uniquely identify interfaces owned by this container.
# This prevents accidental deletion of VTIs from other strongSwan instances on the same host.
INSTANCE_ID="${INSTANCE_ID:-strongswan-local}"

# Sanitize INSTANCE_ID for interface prefix (limit to 10 chars, remove special chars)
IFACE_PREFIX=$(echo "${INSTANCE_ID}" | sed 's/[^a-zA-Z0-9]//g' | cut -c1-10)
echo "Using Instance ID: $INSTANCE_ID (Prefix: $IFACE_PREFIX)"

get_vti_name() {
    local mark=$1
    echo "${IFACE_PREFIX}_v${mark}"
}

cleanup_xfrm() {
    echo "Cleaning up XFRM state/policies..."
    ip xfrm state flush || echo "Warning: Failed to flush xfrm state"
    ip xfrm policy flush || echo "Warning: Failed to flush xfrm policy"
}

cleanup_vtis() {
    echo "Scanning for VTI interfaces managed by instance: $INSTANCE_ID"
    # Find all VTI interfaces that have our ownership alias
    # Format: ip link show matches the alias exactly
    ip -o link show | grep "alias managed-by-$INSTANCE_ID" | awk -F': ' '{print $2}' | cut -d@ -f1 | while read intf; do
        if [ -n "$intf" ]; then
            echo "     Deleting owned VTI: $intf"
            ip link del "$intf" 2>/dev/null || true
        fi
    done
}

if [ "$FLUSH_POLICY_ON_START" == "true" ]; then
    echo "Cleaning up leftovers (FLUSH_POLICY_ON_START=true)..."
    cleanup_xfrm
    
    echo "  -> Flushing routing table ${TABLE_NUM}..."
    ip route flush table ${TABLE_NUM} || echo "Warning: Failed to flush table ${TABLE_NUM}"
    
    cleanup_vtis
else
    echo "Skipping cleanup of leftovers (FLUSH_POLICY_ON_START=$FLUSH_POLICY_ON_START)"
fi

# --- IPv6 Configuration ---
IPV6_ENABLE=${IPV6_ENABLE:-false}
if [ "$IPV6_ENABLE" != "true" ]; then
    echo "IPv6 disabled (IPV6_ENABLE!=true). Configuring strongSwan to ignore IPv6..."
    if ! grep -q "socket-default {" /etc/strongswan.conf || ! grep -q "use_ipv6 = no" /etc/strongswan.conf; then
        cat <<EOF >> /etc/strongswan.conf

charon {
    plugins {
        socket-default {
            use_ipv6 = no
        }
    }
}
EOF
    else
        echo "IPv6 disable config already present in /etc/strongswan.conf"
    fi
else
    echo "IPv6 enabled (IPV6_ENABLE=true)."
fi

# --- CONFIGURATION PARSER ---
# This script extracts connections and their VTI parameters (mark, left, right, subnets)
# Format output: CONN_NAME;MARK;LEFT_IP;RIGHT_IP;LOCAL_SUBNETS;REMOTE_SUBNETS;AUTO_MODE
AWK_SCRIPT='
    function process_conn() {
        if (in_conn && left && right) {
            # Default mark to 0 if not set
            if (mark == "") mark="0";

            # Check if auto_mode is valid
            if (auto_mode == "start" || auto_mode == "add" || auto_mode == "route") {
                print name ";" mark ";" left ";" right ";" left_sub ";" right_sub ";" auto_mode;
            }
        }
        in_conn = 0; name=""; mark=""; left=""; right=""; left_sub=""; right_sub=""; auto_mode="";
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
    in_conn && /^auto=/ { split($0, a, "="); auto_mode=a[2]; }
    in_conn && /^mark=/ { split($0, a, "="); mark=a[2]; }
    in_conn && /^left=/ { split($0, a, "="); left=a[2]; }
    in_conn && /^right=/ { split($0, a, "="); right=a[2]; }
    in_conn && /^leftsubnet=/ { split($0, a, "="); left_sub=a[2]; }
    in_conn && /^rightsubnet=/ { split($0, a, "="); right_sub=a[2]; }

    END { process_conn(); }
'

# Read configs from ipsec.conf
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

# --- CONFIGURATION INJECTION ---
echo "Configuring strongSwan dynamic settings..."
mkdir -p /etc/strongswan.d

# HW Offload Configuration
HW_OFFLOAD=${HW_OFFLOAD:-no}

if [ "$HW_OFFLOAD" == "auto" ]; then
    echo "HW Offload mode: auto. Checking interface $OUT_INTERFACE..."
    if command -v ethtool >/dev/null; then
        # Check for esp-hw-offload: on
        if ethtool -k "$OUT_INTERFACE" 2>/dev/null | grep -q "esp-hw-offload: on"; then
             echo "Detected support for 'esp-hw-offload'. Enabling HW_OFFLOAD."
             HW_OFFLOAD="yes"
        else
             echo "Interface $OUT_INTERFACE does not support 'esp-hw-offload' (or feature is off). Disabling HW_OFFLOAD."
             HW_OFFLOAD="no"
        fi
    else
        echo "Warning: ethtool not found. Cannot auto-detect. Defaulting HW_OFFLOAD to no."
        HW_OFFLOAD="no"
    fi
else
    echo "HW Offload set manually to: $HW_OFFLOAD"
fi

cat <<EOF > /etc/strongswan.d/entrypoint.conf
charon {
  interfaces_use = $OUT_INTERFACE
  install_routes = no
  plugins {
    kernel-netlink {
      hw_offload = $HW_OFFLOAD
    }
  }
}
EOF

# Detect Default Gateway for Legacy Routes
DEFAULT_GW=$(ip route show default | awk '{print $3}' | head -n 1)
echo "Detected Default Gateway: $DEFAULT_GW"

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

cleanup_routes() {
    echo "Cleaning up routes in table ${TABLE_NUM}..."
    ip route flush table ${TABLE_NUM} 2>/dev/null || true
}

setup_vti() {
    local mark=$1
    local local_ip=$2
    local remote_ip=$3
    local vti_name=$(get_vti_name "$mark")

    # VTI MTU: 1400 is the "Golden Number".
    local vti_mtu=1400

    if ip link show "$vti_name" >/dev/null 2>&1; then
        echo "VTI interface $vti_name already exists, resetting..."
        ip link del "$vti_name"
    fi

    echo "Creating VTI Interface: $vti_name (MTU: $vti_mtu, Mark: $mark)"
    ip tunnel add "$vti_name" mode vti local "$local_ip" remote "$remote_ip" key "$mark"
    ip link set "$vti_name" up mtu "$vti_mtu"
    
    # Tag the interface with an alias for stateful management
    ip link set "$vti_name" alias "managed-by-$INSTANCE_ID"

    # Disable policy lookup on the VTI interface itself
    # Disable policy lookup on the VTI interface itself
    sysctl -w "net.ipv4.conf.${vti_name}.disable_policy=1" >/dev/null || echo "Warning: Failed to disable policy on $vti_name"

    # Add routing for remote subnets
    IFS=',' read -ra SUBNETS <<< "$4"
    for subnet in "${SUBNETS[@]}"; do
        echo "  -> Routing $subnet via $vti_name (metric $mark)"
        ip route add "$subnet" dev "$vti_name" metric "$mark"
    done
}

# --- LEGACY ROUTE MONITOR (CRITICAL FOR JUMBO FRAMES) ---
# StrongSwan installs routes into the configured table (default 220) with physical MTU (9000).
# We must force these routes to 1400 to prevent sending Jumbo Packets over VPN.
monitor_legacy_routes() {
    echo "Starting Legacy Route Monitor (Table ${TABLE_NUM}, Target MTU: 1400)..."
    while true; do
        # List all routes in the detected table. If any route lacks "mtu 1400", we fix it.
        # We ignore 'throw' routes which are used for bypass.
        ip route show table ${TABLE_NUM} | while read -r route; do
            if [[ "$route" != *"mtu 1400"* ]] && [[ "$route" != *"throw"* ]]; then
                 # Extract the destination (first word)
                 dst=$(echo "$route" | awk '{print $1}')
                 echo "Fixing MTU for legacy route: $dst in table ${TABLE_NUM}"
                 # We simply re-add the route with the correct MTU, which updates it
                 if ! ip route change table ${TABLE_NUM} $route mtu 1400; then
                     echo "Error changing route: $route"
                 fi
            fi
        done
        # Sleep reduced to 2s to catch routes faster before large packets are sent
        sleep 2
    done
}

apply_firewall() {
    iptables -t nat -I POSTROUTING 1 -j ${CHAIN_NAT} 2>/dev/null || true
    iptables -I FORWARD 1 -j ${CHAIN_FORWARD} 2>/dev/null || true

    # Accept existing connections
    iptables -A ${CHAIN_FORWARD} -m state --state RELATED,ESTABLISHED -j ACCEPT

    local legacy_active=0

    # Parse config to generate rules
    while IFS=';' read -r name mark left right left_sub right_sub auto; do
        if [ -z "$name" ]; then continue; fi

        if [ "$mark" != "0" ]; then
            # --- VTI MODE ---
            local vti_name=$(get_vti_name "$mark")
            echo "Configuring VTI Firewall for $name ($vti_name)..."
            setup_vti "$mark" "$left" "$right" "$right_sub"

            # Allow forwarding over VTI
            iptables -A ${CHAIN_FORWARD} -i "$vti_name" -j ACCEPT
            iptables -A ${CHAIN_FORWARD} -o "$vti_name" -j ACCEPT

            # NAT Exemption (Critical)
            IFS=',' read -ra R_SUBNETS <<< "$right_sub"
            for subnet in "${R_SUBNETS[@]}"; do
                iptables -t nat -A ${CHAIN_NAT} -d "$subnet" -j ACCEPT
            done
        else
            # --- LEGACY POLICY MODE ---
            echo "Configuring Policy Firewall for $name..."
            legacy_active=1

            IFS=',' read -ra R_SUBNETS <<< "$right_sub"
            for subnet in "${R_SUBNETS[@]}"; do
                 iptables -t nat -A ${CHAIN_NAT} -d "$subnet" -j ACCEPT
                 iptables -t nat -A ${CHAIN_NAT} -s "$subnet" -o "$OUT_INTERFACE" -j MASQUERADE
                 iptables -A ${CHAIN_FORWARD} -s "$subnet" -j ACCEPT
                 iptables -A ${CHAIN_FORWARD} -d "$subnet" -j ACCEPT
            done

            # MSS Clamping for Legacy Mode
            # Reduced to 1280 (IPv6 min) to be ultra-safe against all overheads
            # 1. FORWARD: Traffic passing through
            iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1280 2>/dev/null || true
            # 2. OUTPUT: Local traffic (CRITICAL: Fixes iperf from the NAS itself)
            iptables -t mangle -A OUTPUT  -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1280 2>/dev/null || true
        fi
    done <<< "$CONFIG_DATA"

    # --- EXTRA_TUNNELS Support ---
    # Format: ifname:mode:local:remote:key
    # Example: gre1:gre:1.2.3.4:5.6.7.8:100
    if [ -n "$EXTRA_TUNNELS" ]; then
        echo "Configuring Extra Tunnels..."
        for tunnel in $EXTRA_TUNNELS; do
            IFS=':' read -r ifname mode local remote key <<< "$tunnel"
            if [ -z "$ifname" ] || [ -z "$mode" ] || [ -z "$local" ] || [ -z "$remote" ]; then
                echo "Warning: Invalid EXTRA_TUNNELS format: $tunnel"
                continue
            fi
            
            echo "Creating Extra Tunnel: $ifname ($mode) local $local remote $remote key $key"
            
            if ip link show "$ifname" >/dev/null 2>&1; then
                echo "Interface $ifname already exists, resetting..."
                ip link del "$ifname"
            fi
            
            # Build command args
            cmd="ip tunnel add $ifname mode $mode local $local remote $remote"
            if [ -n "$key" ] && [ "$key" != "0" ]; then
                cmd="$cmd key $key"
            fi
            
            # Execute creation
            $cmd
            ip link set "$ifname" up mtu 1400
            
            # Tag the interface with an alias for stateful management
            ip link set "$ifname" alias "managed-by-$INSTANCE_ID"
            
            # Allow forwarding
            iptables -A ${CHAIN_FORWARD} -i "$ifname" -j ACCEPT
            iptables -A ${CHAIN_FORWARD} -o "$ifname" -j ACCEPT
            
            # Disable policy on interface (useful for VTI/GRE protected by IPsec)
            sysctl -w "net.ipv4.conf.${ifname}.disable_policy=1" >/dev/null || true
        done
    fi


    # Start Route Monitor if we have legacy connections
    if [ "$legacy_active" -eq 1 ]; then
        monitor_legacy_routes &
    fi
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
    cleanup_routes
    cleanup_xfrm
    cleanup_vtis
    if [ -n "$IPSEC_PID" ]; then kill "$IPSEC_PID"; fi
    if [ -f /var/run/frr/bgpd.pid ]; then kill $(cat /var/run/frr/bgpd.pid) 2>/dev/null || true; fi
    if [ -f /var/run/frr/zebra.pid ]; then kill $(cat /var/run/frr/zebra.pid) 2>/dev/null || true; fi
    exit 0
}

start_frr() {
    if [ -f /etc/frr/frr.conf ] || [ -f /etc/frr/bgpd.conf ]; then
        echo "Starting FRR (Zebra & BGPd)..."
        install -d -m 755 -o frr -g frr /var/run/frr
        
        # Add root to frr/frrvty group to allow vtysh access
        addgroup root frr 2>/dev/null || true
        addgroup root frrvty 2>/dev/null || true
        
        # Ensure daemons file exists and enable bgpd if not present
        if [ ! -f /etc/frr/daemons ]; then
             echo "Creating default /etc/frr/daemons..."
             cat <<EOF > /etc/frr/daemons
bgpd=yes
ospfd=yes
ospf6d=no
ripd=no
ripngd=no
isisd=no
pimd=no
ldpd=no
nhrpd=no
eigrpd=no
babeld=no
sharpd=no
pbrd=no
bfdd=no
fabricd=no
vrrpd=no
pathd=no
EOF
             chown frr:frr /etc/frr/daemons
        fi
        
        # Ensure vtysh.conf exists
        if [ ! -f /etc/frr/vtysh.conf ]; then
            echo "Creating default /etc/frr/vtysh.conf..."
            echo "service integrated-vtysh-config" > /etc/frr/vtysh.conf
            chown frr:frrvty /etc/frr/vtysh.conf
        fi
        
        # Ensure config is readable by frr
        if [ -f /etc/frr/frr.conf ]; then
            chown frr:frr /etc/frr/frr.conf
            chmod 640 /etc/frr/frr.conf
        fi
        
        # Cleanup FRR temp files
        rm -rf /var/tmp/frr/*
        install -d -m 755 -o frr -g frr /var/tmp/frr

        # Start daemons with FD limit to avoid warnings
        /usr/lib/frr/zebra -d -A 127.0.0.1 -f /etc/frr/frr.conf --limit-fds 100000
        /usr/lib/frr/bgpd -d -A 127.0.0.1 -f /etc/frr/frr.conf --limit-fds 100000
    else
        echo "No FRR configuration found (/etc/frr/frr.conf). Skipping BGP/OSPF."
    fi
}

cleanup_firewall
cleanup_routes
create_chains
apply_firewall

echo "Starting strongSwan..."
ipsec start --nofork > "$LOG_FILE" 2>&1 &
IPSEC_PID=$!

# Start FRR if configured
start_frr

sleep 5

# Force reload to ensure all configs are picked up by charon
echo "Reloading strongSwan configuration..."
ipsec reload || true
sleep 2

# Log loaded connections for debugging
echo "--- Loaded Connections ---"
ipsec status || true
echo "--------------------------"

# Start connections
while IFS=';' read -r name mark left right left_sub right_sub auto_mode; do
    if [ -z "$name" ]; then continue; fi

    if [ "$auto_mode" = "start" ]; then
         echo "Connection $name is auto=start, skipping explicit up."
    elif [ "$auto_mode" = "add" ] || [ "$auto_mode" = "route" ]; then
         echo "Connection $name is auto=$auto_mode, skipping explicit up (passive/trap)."
    else
         # Should not happen with new parser, but for safety:
         echo "Connection $name has unknown mode $auto_mode, attempting ipsec up..."
         ipsec up "$name" >/dev/null 2>&1 || true
    fi
done <<< "$CONFIG_DATA"

# --- ROUTING INSTALLATION (with optional ECMP Load Balancing) ---
# We use an associative array (requires bash) to group interfaces by destination subnet.
declare -A SUB_IFACES

# First, collect all interfaces per subnet
while IFS=';' read -r name mark left right left_sub right_sub auto; do
    if [ -z "$name" ] || [ -z "$right_sub" ]; then continue; fi
    if [ "$mark" != "0" ]; then
        iface=$(get_vti_name "$mark")
        # Split multiple right subnets (comma-separated)
        IFS=',' read -ra R_SUBS <<< "$right_sub"
        for sub in "${R_SUBS[@]}"; do
            SUB_IFACES["$sub"]+="$iface "
        done
    fi
done <<< "$CONFIG_DATA"

# Now install routes
for sub in "${!SUB_IFACES[@]}"; do
    ifaces=(${SUB_IFACES[$sub]})
    if [ "$LOAD_BALANCE" == "true" ] && [ ${#ifaces[@]} -gt 1 ]; then
        echo "Installing ECMP Load Balanced route for $sub via [${ifaces[*]}]"
        # Build nexthop string
        cmd="ip route replace $sub table $TABLE_NUM"
        for iface in "${ifaces[@]}"; do
            cmd="$cmd nexthop dev $iface weight 1"
        done
        $cmd || echo "Warning: Failed to install ECMP route for $sub"
    else
        # Single interface or load balancing disabled
        # If multiple exist but LB is off, the first one in the list wins (consistent with legacy behavior)
        iface=${ifaces[0]}
        echo "Installing route for $sub via $iface (table $TABLE_NUM)"
        ip route replace "$sub" dev "$iface" table "$TABLE_NUM" || true
    fi
done

# Handle Legacy Routes (non-VTI connections)
while IFS=';' read -r name mark left right left_sub right_sub auto; do
    if [ -z "$name" ] || [ -z "$right_sub" ] || [ "$mark" != "0" ]; then continue; fi
    IFS=',' read -ra R_SUBS <<< "$right_sub"
    for sub in "${R_SUBS[@]}"; do
        # Legacy Mode
        echo "Adding Legacy route for $name: $sub"
        if [ -n "$DEFAULT_GW" ]; then
             ip route replace "$sub" via "$DEFAULT_GW" dev "$OUT_INTERFACE" table "$TABLE_NUM" || true
        else
             ip route replace "$sub" dev "$OUT_INTERFACE" table "$TABLE_NUM" || true
        fi
    done
done <<< "$CONFIG_DATA"

# --- BACKGROUND RECONCILER ---
# Periodically verify interfaces, routes, and firewall rules are intact.
reconcile_loop() {
    echo "Starting Background Reconciler..."
    while true; do
        sleep 30
        
        # Verify Firewall Chains exist
        if ! iptables -L ${CHAIN_FORWARD} >/dev/null 2>&1; then
            echo "RECONCILE: Firewall chains missing, reapplying..."
            cleanup_firewall
            create_chains
            apply_firewall
        fi

        # Verify Jump Rules
        if ! iptables -S FORWARD | grep -q "${CHAIN_FORWARD}"; then
             echo "RECONCILE: Forward jump missing, reapplying..."
             iptables -I FORWARD 1 -j ${CHAIN_FORWARD} 2>/dev/null || true
        fi

        # Verify Interfaces
        while IFS=';' read -r name mark left right left_sub right_sub auto; do
            if [ -z "$name" ]; then continue; fi
            if [ "$mark" != "0" ]; then
                vti_name=$(get_vti_name "$mark")
                # Check if interface exists and is tagged correctly
                if ! ip -o link show "$vti_name" | grep -q "alias managed-by-$INSTANCE_ID"; then
                    echo "RECONCILE: VTI $vti_name missing or untagged, recreating..."
                    setup_vti "$mark" "$left" "$right" "$right_sub"
                fi
            fi
        done <<< "$CONFIG_DATA"

        # Verify Routing Health (Reapply all routes to ensure ECMP/Single matches intended state)
        # This is simpler than incremental diffing for complex ECMP routes.
        # Collect and compare
        local current_subs=$(ip route show table "$TABLE_NUM" | awk '{print $1}')
        # We re-run the routing logic if any subnet is missing or if we suspect corruption.
        # For simplicity in this shell script, we just re-verify the active routes.
        for sub in "${!SUB_IFACES[@]}"; do
             if ! ip route show table "$TABLE_NUM" | grep -q "$sub"; then
                 echo "RECONCILE: Routing entry for $sub missing, restoring..."
                 # Trigger re-installation (just for this subnet)
                 ifaces=(${SUB_IFACES[$sub]})
                 if [ "$LOAD_BALANCE" == "true" ] && [ ${#ifaces[@]} -gt 1 ]; then
                     cmd="ip route replace $sub table $TABLE_NUM"
                     for iface in "${ifaces[@]}"; do cmd="$cmd nexthop dev $iface weight 1"; done
                     $cmd || true
                 else
                     ip route replace "$sub" dev "${ifaces[0]}" table "$TABLE_NUM" || true
                 fi
             fi
        done
    done
}

echo "Initialization complete."
tail -f "$LOG_FILE" &
reconcile_loop &
wait "$IPSEC_PID"
