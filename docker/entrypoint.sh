#!/bin/sh
set -e

LOG_FILE="/var/log/strongswan.log"

shutdown() {
  echo "Shutting down strongSwan..."
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
