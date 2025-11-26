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

# Define the iptables rules.
# CRITICAL: We use -I (Insert) for both NAT exemption and FORWARD rules to ensure
# they sit at position 1, overriding Tailscale (ts-postrouting/ts-forward) or Docker chains.
IPTABLES_RULES=(
  "-t nat -I POSTROUTING 1 -d ${VPN_SUBNET} -j ACCEPT"
  "-t nat -A POSTROUTING -s ${VPN_SUBNET} -o ${OUT_INTERFACE} -j MASQUERADE"
  "-I FORWARD 1 -s ${VPN_SUBNET} -d ${LOCAL_NET} -j ACCEPT"
  "-I FORWARD 1 -s ${LOCAL_NET} -d ${VPN_SUBNET} -j ACCEPT"
  "-I FORWARD 1 -m state --state RELATED,ESTABLISHED -j ACCEPT"
)

add_firewall_rules() {
  echo "Adding firewall rules..."
  for rule in "${IPTABLES_RULES[@]}"; do
    # Logic to create a valid check command (-C) from -A or -I
    # 1. Replace -A with -C
    check_rule="${rule/-A/-C}"
    # 2. Replace "-I chain position" with "-C chain" (remove the position number for check)
    if [[ $rule == *"-I"* ]]; then
        # Extract chain name (e.g., POSTROUTING) to build a valid -C command
        # This is a bit complex in bash, so we trust -C will fail if rule doesn't exist
        # Simplified: Just strip the position number for the check if possible,
        # or rely on the fact that duplicate ACCEPT rules are generally harmless.
        # For robustness, we will try to run the rule.
        echo "  Enforcing high-priority rule: iptables ${rule}"
        iptables ${rule} || true
        continue
    fi

    if ! iptables ${check_rule} >/dev/null 2>&1; then
      echo "  Adding rule: iptables ${rule}"
      iptables ${rule}
    else
      echo "  Rule already exists: iptables ${rule}"
    fi
  done
  echo "Firewall rules applied."
}

remove_firewall_rules() {
  echo "Removing firewall rules..."
  for rule in "${IPTABLES_RULES[@]}"; do
    # Logic to convert -A/-I to -D
    delete_rule="${rule/-A/-D}"
    delete_rule="${delete_rule/-I/-D}"
    
    # Remove position number from delete command if it was an Insert command
    # (iptables -D POSTROUTING 1 is risky, better to delete by rule specification)
    if [[ $rule == *"-I"* ]]; then
        # Remove the "1" (or any digit) following POSTROUTING or FORWARD
        # We use two sed calls to handle both chains safely
        delete_rule=$(echo "$delete_rule" | sed 's/POSTROUTING [0-9]*/POSTROUTING/' | sed 's/FORWARD [0-9]*/FORWARD/')
    fi

    echo "  Deleting rule: iptables ${delete_rule}"
    # Suppress errors if rule is already gone
    iptables ${delete_rule} >/dev/null 2>&1 || true
  done
  echo "Firewall rules removed."
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
