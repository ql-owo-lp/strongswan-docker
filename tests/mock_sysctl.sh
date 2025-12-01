#!/bin/bash
# Mock sysctl script for testing

# Log all arguments to the specified log file
echo "sysctl $@" >> "${IPTABLES_MOCK_LOG}"

# Always return success
exit 0
