#!/bin/bash
# Mock iptables script for testing

# Log all arguments to the specified log file
echo "iptables $@" >> "${IPTABLES_MOCK_LOG}"

# Simulate the behavior of iptables -C (check)
# This mock will always return a non-zero exit code to simulate that the rule does not exist.
# This ensures that the entrypoint script will always try to add the rules.
if [ "$1" == "-C" ]; then
  exit 1
else
  exit 0
fi
