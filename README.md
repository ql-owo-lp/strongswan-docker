# strongSwan Docker Image

This repository contains the files to build a Docker image for strongSwan, an open-source IPsec-based VPN solution. The image is designed to be simple, lightweight, and configurable for use in a home server or NAS environment.

## Features

- Based on Alpine Linux for a small footprint.
- Multi-architecture build support (amd64, arm64, arm/v7).
- Configurable via mounted `ipsec.conf` and `ipsec.secrets` files.
- Automatic IP forwarding and `iptables` NAT configuration.

## How It Works

The Docker container runs the strongSwan daemon in `host` network mode, which gives it the necessary privileges to manipulate the host's network stack. This is required for the VPN to function correctly.

The `entrypoint.sh` script performs the following actions on startup:

1.  **Enables IP Forwarding**: It sets `net.ipv4.ip_forward = 1` on the host system, which is essential for routing traffic between the VPN clients and the local network.
2.  **Configures `iptables`**: It adds firewall rules to allow traffic to be forwarded between the VPN subnet and the local network. It also sets up a `MASQUERADE` rule, which performs Network Address Translation (NAT) for traffic going from the VPN clients to the outside world.
3.  **Starts strongSwan**: It launches the `ipsec` daemon to handle the VPN connections.
4.  **Brings Up Tunnels**: It automatically brings up any connections in `ipsec.conf` that are not marked with `auto=start`.

### Networking Configuration

The `entrypoint.sh` script is responsible for configuring the necessary networking rules on the host. It does this in a non-destructive way by adding and removing its specific `iptables` rules, ensuring it does not interfere with other firewall configurations.

You can configure the network settings by passing environment variables to the container. The following variables are supported, with sensible defaults provided:

-   `LOCAL_NET`: The CIDR of your local network (default: `192.168.0.0/16`).
-   `VPN_SUBNET`: The virtual IP subnet for VPN clients (default: `10.10.0.0/24`).
-   `OUT_INTERFACE`: The primary network interface of your NAS/server. This is now optional and will be auto-detected if not provided.
-   `IPTABLES_CHAIN_PREFIX`: A custom prefix for the `iptables` chains created by the container (default: `STRONGSWAN`). This allows you to run multiple instances of the container without their firewall rules conflicting.

These variables can be set in the `docker-compose.yml` file.

## Testing

This repository includes an end-to-end (e2e) test suite to verify the correctness of the `iptables` rule management. The tests ensure that the firewall rules are created, cleaned up, and managed correctly, even in cases of unclean shutdown.

To run the tests, execute the following script from the root of the repository:

```bash
sudo ./test/e2e_iptables.sh
```

**Note**: The test script requires `sudo` because it needs to interact with `iptables` and run Docker containers. It will build a temporary Docker image for testing and clean up all resources (containers, images, and `iptables` rules) it creates.

## Usage

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/ql-owo-lp/strongswan-docker.git
    cd strongswan-docker
    ```

2.  **Customize your configuration:**
    -   Create an `ipsec.conf` file with your VPN connection details.
    -   Create an `ipsec.secrets` file with your credentials.

3.  **Build the Image (Optional):**

    This repository is configured with a GitHub Action to automatically build and publish the Docker image to `ghcr.io`. However, if you want to build the image manually, you can use the provided script:
    ```bash
    # Build and push to ghcr.io
    ./build-docker.sh ghcr.io/your-username/your-repo

    # Build and push to Docker Hub
    ./build-docker.sh your-dockerhub-username/your-repo
    ```

4.  **Run the Container:**
    Use `docker-compose.yml` to run the container. Make sure your `ipsec.conf` and `ipsec.secrets` are in the same directory.
    ```bash
    docker-compose up -d
    ```

## Troubleshooting

-   **Connectivity issues**: Double-check the `LOCAL_NET`, `VPN_SUBNET`, and `OUT_INTERFACE` variables in `docker/entrypoint.sh`.
-   **Logs**: Check the container logs for connection errors: `docker logs ipsec-gateway`.

This updated configuration should resolve issues where the VPN connects but traffic is not routed correctly.
