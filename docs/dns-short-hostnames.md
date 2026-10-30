# DNS settings and short hostnames with Talos 1.14

With Talos 1.14 the role renders DNS settings into a `ResolverConfig`
document. Besides `talos_proxmox_nameservers` it can also set search domains
and host DNS options.

| Variable | Default | Purpose |
|---|---|---|
| `talos_proxmox_nameservers` | `[1.1.1.1, 8.8.8.8]` | DNS servers |
| `talos_proxmox_search_domains` | `[]` | Search domains (`searchDomains.domains`) |
| `talos_proxmox_host_dns` | `{}` | `hostDNS` settings, rendered as is |

An empty value means the setting is not rendered at all, so existing
configurations do not change.

```yaml
talos_proxmox_nameservers:
  - 192.168.100.2
talos_proxmox_search_domains:
  - example.com
talos_proxmox_host_dns:
  enabled: true
  forwardKubeDNSToHost: true
  resolveMemberNames: true
```

renders into the `ResolverConfig` document of the machine configuration:

```yaml
apiVersion: v1alpha1
kind: ResolverConfig
nameservers:
  - address: 192.168.100.2
searchDomains:
  domains:
    - example.com
hostDNS:
  enabled: true
  forwardKubeDNSToHost: true
  resolveMemberNames: true
```

The variables are only used for Talos `v1.14.0` and later. Older releases use
the legacy `machine.network.nameservers` path, which only supports name servers.

## Using short node names with `talosctl`

Using short hostnames such as `talos-01` in `talosctl config nodes` can fail
with errors like:

```text
dns: A record lookup error: lookup talos-01 on 127.0.0.53:53: server misbehaving
```

The names given to `--nodes` are resolved on the endpoint node, not on your
workstation, so DNS records that work from your workstation do not help.
Using FQDNs as node names fails TLS verification, because the Talos API
certificate is issued for the short hostname only.

In the cluster this was written for, short names started to resolve when
`hostDNS.resolveMemberNames` was enabled on every node (so the endpoint can
resolve member names from Talos discovery data):

```yaml
talos_proxmox_host_dns:
  enabled: true
  resolveMemberNames: true
```

This is an observation from one cluster, not a general guarantee. If it does
not help in your environment, use IP addresses in `talosctl config nodes`.

## Applying a `ResolverConfig` to running nodes

If you patch a `ResolverConfig` onto a node that already has one, a plain list
merge can duplicate the name servers. To replace the document instead, delete
the old fields first and then set them again, for example:

```yaml
apiVersion: v1alpha1
kind: ResolverConfig
nameservers:
  $patch: delete
searchDomains:
  $patch: delete
hostDNS:
  $patch: delete
---
apiVersion: v1alpha1
kind: ResolverConfig
nameservers:
  - address: 192.168.100.2
searchDomains:
  domains:
    - example.com
hostDNS:
  enabled: true
  resolveMemberNames: true
```

Apply it to every node, not only one, so all nodes get the same settings:

```bash
talosctl patch mc --nodes <node-ip>[,<node-ip>...] --patch @resolver.yaml
```

When a cluster is installed with this role, set the variables above instead, so
the DNS settings come from a single source.
