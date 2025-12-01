#!/bin/bash
# Mock ip script for testing

# Log all arguments to the specified log file
echo "ip $@" >> "${IPTABLES_MOCK_LOG}"

# Handle 'ip route' command for interface detection
# The script calls: ip route | grep default | awk '{print $5}'
# So we need 'ip route' to output a line with 'default'.
if [ "$1" == "route" ] && [ -z "$2" ]; then
    echo "default via 172.17.0.1 dev eth0"
    exit 0
fi

# Handle 'ip link show vti*' to check if interface exists.
# We return 1 (error) to simulate that the interface does NOT exist,
# so the script proceeds to create it without trying to delete it first.
if [[ "$*" == *"link show vti"* ]]; then
    exit 1
fi

# For all other commands (tunnel add, link set, route add, etc.), just return success.
exit 0
