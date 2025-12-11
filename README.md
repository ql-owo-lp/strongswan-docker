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

**Important:** For the container to be able to modify the host's firewall rules, it is essential that it is run with `network_mode: "host"`, as configured in the `docker-compose.yml` file.

### Networking Configuration

The `entrypoint.sh` script is responsible for configuring the necessary networking rules on the host. It now dynamically infers the local and remote subnets from your `ipsec.conf` file. For any connection marked with `auto=start`, the script will use the `leftsubnet` as your local network and the `rightsubnet` as the remote VPN network.

It will then automatically generate the appropriate `iptables` rules to allow traffic between these subnets. This removes the need to manually set the `LOCAL_NET` and `VPN_SUBNET` environment variables.

If the script cannot find any suitable connections in your `ipsec.conf`, it will fall back to using the environment variables or the default values.

### Custom Tunnels
You can define additional tunnel interfaces (independent of ipsec.conf parsing) using the `EXTRA_TUNNELS` environment variable. This is useful for GRE, IPIP, or manual VTI configurations.

**Format**: `ifname:mode:local:remote:key` (space-separated)

**Example**:
```yaml
environment:
  - EXTRA_TUNNELS=gre1:gre:1.2.3.4:5.6.7.8:100 vti50:vti:1.2.3.4:5.6.7.9:50
```

### strongSwan Configuration

The container includes a default `strongswan.conf` file with the following settings:
-   `install_routes = yes`: strongSwan will install routes into a separate routing table.
-   `routing_table = 230`: Routes are installed into table 230 to avoid conflicts with the host's main routing table.
-   `duplicheck.enable = yes`: Enables the `duplicheck` plugin to prevent multiple connections from the same peer.

You can override this file by creating your own `strongswan.conf` and mounting it as a volume in the `docker-compose.yml` file.

## Usage

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/ql-owo-lp/strongswan-docker.git
    cd strongswan-docker
    ```

2.  **Customize your configuration:**
    -   Create an `ipsec.conf` file with your VPN connection details.
    -   Create an `ipsec.secrets` file with your credentials.
    -   (Optional) Create a `strongswan.conf` to override the default settings.

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

### A Note on `iptables` Compatibility

Modern Linux distributions are transitioning from the original `iptables` to a newer version based on the `nftables` kernel framework. The version of `iptables` in the container must match the version used by the host OS for the firewall rules to be applied correctly.

This repository now builds two versions of the Docker image to ensure compatibility:

-   `:legacy`: Based on Alpine 3.15, for hosts that still use the original `iptables`.
-   `:nft`: Based on Alpine 3.19, for hosts that have transitioned to `iptables-nft`.

If you are using the pre-built images, make sure to choose the correct tag for your host system in the `docker-compose.yml` file.

If you are building the image manually, the `build-docker.sh` script will automatically build both versions and tag them with `:legacy` and `:nft`.

## Troubleshooting

-   **Firewall rules not appearing on the host:** If the container logs indicate that `iptables` rules are being created but they do not appear on your host system (e.g., `iptables -L`), it is almost certainly due to an `iptables` version mismatch.
    1.  Check the container logs: `docker logs ipsec-gateway`.
    2.  At the top of the logs, you will see the `iptables` version information from the container. For example:
        ```
        iptables v1.8.9 (legacy)
        ```
        or
        ```
        iptables v1.8.10 (nf_tables)
        ```
    3.  On your host system, run `iptables --version` to see which version your host is using.
    4.  Ensure that the `iptables` version in the container matches the version on your host. If they do not match, you must use the image tag that corresponds to your host's `iptables` version (`:legacy` or `:nft`).

-   **Connectivity issues**: Double-check your `ipsec.conf` file to ensure the `leftsubnet` and `rightsubnet` values are correct.
-   **Logs**: Check the container logs for any other connection errors: `docker logs ipsec-gateway`.

This updated configuration should resolve issues where the VPN connects but traffic is not routed correctly.
