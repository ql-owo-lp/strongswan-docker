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

# Define the iptables rules to be added. This makes them easier to manage.
# Using variables helps avoid duplicating rule definitions in the add and delete logic.
IPTABLES_RULES=(
  "-t nat -A POSTROUTING -s ${VPN_SUBNET} -o ${OUT_INTERFACE} -j MASQUERADE"
  "-A FORWARD -s ${VPN_SUBNET} -d ${LOCAL_NET} -j ACCEPT"
  "-A FORWARD -s ${LOCAL_NET} -d ${VPN_SUBNET} -j ACCEPT"
  "-A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT"
)

add_firewall_rules() {
  echo "Adding firewall rules..."
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

remove_firewall_rules() {
  echo "Removing firewall rules..."
  for rule in "${IPTABLES_RULES[@]}"; do
    delete_rule="${rule/-A/-D}"
    check_rule="${rule/-A/-C}"
    if iptables ${check_rule} >/dev/null 2>&1; then
      echo "  Deleting rule: iptables ${delete_rule}"
      iptables ${delete_rule}
    fi
  done
  echo "Firewall rules removed."
}

# Enable IP forwarding. This is essential for the container to act as a router.
echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null

# Add the firewall rules at startup.
add_firewall_rules
# --- End of Network Configuration ---

shutdown() {
  echo "Shutting down strongSwan..."
  remove_firewall_rules

  # It's good practice to kill the specific process on shutdown
  # before calling ipsec stop, to be certain.
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
    # This block processes the file line by line
    /conn %default/ {next} # Skip the default connection
    /conn/ {
        # When a new connection block starts
        conn_name = $2;
        auto_start = 0;
    }
    /auto=start/ {
        # If auto=start is found inside a connection block, flag it
        auto_start = 1;
    }
    # This block runs at the end of each block of lines (a "paragraph" separated by blank lines)
    /^$/ {
        if (!auto_start && conn_name != "") {
            print conn_name;
        }
        conn_name = "";
    }
    # This block runs at the end of the entire file to catch the last connection
    END {
        if (!auto_start && conn_name != "") {
            print conn_name;
        }
    }
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

# Start tailing the log file in the background to forward logs to docker logs
tail -f "$LOG_FILE" &

wait "$IPSEC_PID"
