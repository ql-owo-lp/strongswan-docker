# Use a recent, specific version of Alpine for stability
FROM alpine

# Install strongSwan and basic network tools.
RUN apk update && \
    apk add --no-cache \
        strongswan \
        bash \
        iproute2 \
        iptables && \
    rm -rf /var/cache/apk/*

# Copy the strongSwan daemon configuration into the image
COPY strongswan.conf /etc/strongswan.conf

# Copy the entrypoint script into the image and make it executable
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# This is the command that will run when the container starts
ENTRYPOINT ["/entrypoint.sh"]
