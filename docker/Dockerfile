# --- Build Configuration ---
# Accept a build argument to switch between iptables modes.
# - 'legacy': Uses Alpine 3.15, which has the older iptables.
# - 'nft':    Uses Alpine 3.19, which has iptables-nft.
ARG IPTABLES_MODE=legacy
ARG ALPINE_VERSION=3.15
# Choose the Alpine version based on the selected iptables mode
FROM mirror.gcr.io/library/alpine:${ALPINE_VERSION}

# --- Package Installation ---
# Install strongSwan and essential network tools. The specific packages
# will be installed based on the Alpine version.
# Added gawk for robust configuration parsing.
RUN apk update && \
    apk add --no-cache \
    strongswan \
    iproute2 \
    iptables \
    gawk \
    openssl \
    bash \
    frr && \
    rm -rf /var/cache/apk/*

# --- Configuration ---
# Copy the strongSwan daemon configuration into the image.
COPY strongswan.conf /etc/strongswan.conf

# Copy the entrypoint script, which manages the container's startup
# and shutdown procedures, and make it executable.
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# --- Execution ---
# Define the entrypoint that will be executed when the container starts.
ENTRYPOINT ["/entrypoint.sh"]
