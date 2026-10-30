# HAProxy on pfSense as a load balancer for the Talos API

This guide puts a single, stable name in front of the three control plane
nodes' Talos API (TCP `50000`) using the HAProxy package on pfSense.
The names and addresses below are examples; replace them with your own.

| Item | Example |
|---|---|
| Talos API endpoint name | `talos-api.example.com` |
| Control plane nodes | `talos-01` `192.168.100.11`, `talos-02` `192.168.100.12`, `talos-03` `192.168.100.13` |
| Kubernetes VIP (`talos_proxmox_cluster_shared_ip`) | `192.168.100.10` |
| Talos API port | `50000` |

```text
talosctl
   |
   | TLS with client certificate
   v
talos-api.example.com:50000
   |
   | HAProxy, TCP passthrough
   +-- 192.168.100.11:50000
   +-- 192.168.100.12:50000
   +-- 192.168.100.13:50000
```

HAProxy does not terminate TLS. Talos presents its own certificate and
authenticates the client certificate itself.

The Kubernetes VIP is not part of this path. It serves the Kubernetes API on
port `6443`.

The field names follow the pfSense HAProxy package UI and can differ slightly
between versions.

## 1. DNS and listen address

Create a DNS record that points the endpoint name at the pfSense address that
HAProxy listens on:

```text
talos-api.example.com -> <HAProxy listen IP on pfSense>
```

The listen IP must belong to pfSense, not to a Talos node. Do not point this
name at the Kubernetes VIP.

HAProxy can share an interface and IP with the pfSense web GUI as long as the
ports differ (GUI `443`, HAProxy `50000`), so the GUI port does not need to
change.

## 2. Backend

**Services -> HAProxy -> Backend -> Add**

| Field | Value |
|---|---|
| Name | `talos_controlplanes` |
| Balance | `Round robin` |

Add one server per control plane node (port `50000`, active). For every server:

- **Encrypt (SSL)**: off
- **SSL checks**: off, if shown
- **Send PROXY protocol**: off, if shown

Leaving *Encrypt (SSL)* off does not remove Talos' encryption. The original
TLS connection passes through HAProxy unchanged.

Health checks and timeouts:

| Field | Value |
|---|---|
| Health check method | `Basic` (TCP connect) |
| Check frequency | `3000` ms |
| Connection timeout | `5000` ms |
| Server timeout | `3600000` ms |

Do not choose an HTTP or HTTPS check, and do not leave the check frequency
empty: in a TCP backend an empty value can mean that no checks are made.

## 3. Frontend

**Services -> HAProxy -> Frontend -> Add**

| Field | Value |
|---|---|
| Name | `talos_api` |
| Status | Active |
| Shared Frontend | Off |
| Type | `tcp` |
| Default Backend | `talos_controlplanes` |
| Client timeout | `3600000` ms |

External address:

| Field | Value |
|---|---|
| Listen address | The management interface address you chose |
| Port | `50000` |
| SSL Offloading | **Off** |
| Advanced | Empty |

Prefer a specific listen address over all addresses. No certificate, SNI or
Host ACLs, HTTP redirects or HTTP/2 settings are needed.

Save and choose **Apply Changes**. If HAProxy is not enabled yet, enable it in
**Services -> HAProxy -> Settings**.

## 4. Firewall rules

Allow the connection on the interface that your management host or VPN clients
arrive on:

| Field | Value |
|---|---|
| Action | Pass |
| Protocol | TCP |
| Source | Your management hosts or management/VPN network |
| Destination | HAProxy listen IP |
| Destination port | `50000` |

Do not expose the Talos API from WAN to everyone. Also make sure pfSense can
reach TCP port `50000` on every backend node.

## 5. Certificate SAN for the endpoint name

With TLS passthrough the client verifies the Talos node certificate against the
endpoint name, so every control plane node's certificate must contain
`talos-api.example.com`.

The right setting is `machine.certSANs`. Do not use `cluster.apiServer.certSANs`,
which applies to the Kubernetes API.

Preview with direct IP addresses first:

```bash
talosctl \
  --endpoints 192.168.100.12 \
  --nodes 192.168.100.11,192.168.100.12,192.168.100.13 \
  patch mc v1alpha1 \
  --patch 'machine:
  certSANs:
    - talos-api.example.com' \
  --dry-run
```

If the name is missing and the diff contains only the expected addition, run
the same command without `--dry-run` and let the certificates refresh. Do not
repeat the patch unnecessarily, because a list patch can add duplicates. Do not
skip TLS verification or enable SSL offloading as a workaround.

Add the SAN to your machine configuration source as well (inventory or patch
files), so a reinstall does not lose it.

## 6. Short node names in `--nodes`

The endpoint node resolves the names given to `--nodes`, not your workstation.
Enabling the host DNS member name resolution on every node lets the endpoint
resolve short member names from Talos discovery data, so hostnames can stay
short:

```yaml
talos_proxmox_host_dns:
  enabled: true
  resolveMemberNames: true
```

See [dns-short-hostnames.md](dns-short-hostnames.md).

## 7. Testing

In the HAProxy **Stats** view all backend servers should be **UP**. That only
shows that the TCP port is reachable, not that the cluster is healthy.

Test before changing the stored endpoint:

```bash
talosctl --endpoints talos-api.example.com --nodes talos-01,talos-02,talos-03 version
talosctl --endpoints talos-api.example.com --nodes talos-01,talos-02,talos-03 get rd
```

One successful command does not prove that every backend works: a gRPC
connection can stay on the same backend. To check each backend, leave only one
server active in HAProxy at a time and open a new connection. Re-enable all
servers afterwards.

If you see `certificate is valid for talos-01, not talos-api.example.com`,
check the SAN setting in section 5.

## 8. Default endpoint and bypass

When the tests pass, make HAProxy the endpoint of the current context:

```bash
talosctl config endpoint talos-api.example.com
talosctl config nodes talos-01 talos-02 talos-03
```

HAProxy makes a shared address easier to use, but it adds a dependency on
pfSense, the HAProxy service and DNS. A single load balancer does not by itself
improve the availability of three direct endpoints.

To bypass the load balancer for a single maintenance command:

```bash
talosctl --endpoints 192.168.100.12 --nodes 192.168.100.11 version
```

To restore direct endpoints:

```bash
talosctl config endpoint 192.168.100.11 192.168.100.12 192.168.100.13
```

The endpoint list is not a primary/backup priority list: `talosctl` can use any
address in it for load balancing and failover.

## References

- [Talos: talosctl, endpoints and nodes](https://docs.siderolabs.com/talos/v1.14/learn-more/talosctl)
- [Talos: MachineConfig and machine.certSANs](https://docs.siderolabs.com/talos/v1.14/reference/configuration/v1alpha1/config#machine)
- [Netgate: pfSense administration settings](https://docs.netgate.com/pfsense/en/latest/config/advanced-admin.html)
- [Netgate: securely administering a firewall remotely](https://docs.netgate.com/pfsense/en/latest/recipes/remote-firewall-administration.html)
