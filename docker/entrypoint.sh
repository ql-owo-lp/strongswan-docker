#!/bin/sh
set -e

# This function is called when the container is stopped
shutdown() {
  echo "Shutting down strongSwan..."
  # Tell strongSwan to gracefully stop all connections
  ipsec stop
  exit 0
}

# Trap TERM and INT signals to call our shutdown function
trap 'shutdown' TERM INT

echo "Starting strongSwan daemon in the background..."
# The debug levels are controlled by /etc/strongswan.conf, not command-line flags.
ipsec start

# Wait a moment for the daemon to initialize
sleep 5

# Find all connection names from the config file (lines starting with "conn")
# and handle potential leading whitespace.
CONN_NAMES=$(grep -E '^\s*conn\s+' /etc/ipsec.conf | grep -v '%default' | awk '{print $2}')

if [ -z "$CONN_NAMES" ]; then
  echo "Warning: No connections found in /etc/ipsec.conf to automatically start."
else
  echo "Found connections to automatically start:"
  for conn in $CONN_NAMES; do
    echo "- $conn"
  done
  echo
  for conn in $CONN_NAMES; do
    echo "--> Attempting to bring up tunnel: $conn"
    # Execute 'ipsec up' for each connection found
    ipsec up "$conn"
  done
fi

echo "Initialization complete. Container is running and will stay alive."
echo "Use 'docker logs -f ipsec-gateway' to monitor."

# This is a common pattern to keep a container running.
# The `wait` command pauses the script here.
# The `&` runs `sleep infinity` in the background, and we wait for it.
# When the container is stopped, the `shutdown` function is called by the trap,
# and then the script exits.
sleep infinity &
wait $!

