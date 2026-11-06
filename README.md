# talos_proxmox Ansible Role

This Ansible role automates the provisioning and configuration of a Talos-based Kubernetes cluster on Proxmox.

The role is intended for provisioning a new cluster. Adding nodes to an
existing cluster is not supported.

## Features

- Automated VM provisioning on Proxmox
- Talos OS configuration and bootstrapping
- Cilium CNI installation and VLAN network setup (optional)
- Configuration of static kubernetes resources (for example secrets)

## Requirements

- Ansible >= 2.12
- Collections:
   - community.general
   - community.proxmox
   - kubernetes.core
   - ansible.utils
- Python >= 3.9 on the control host
- Python packages: `requests`, `kubernetes>=24.2.0`, `PyYAML>=3.11`, `jsonpatch`, `proxmoxer`, `jmespath`, `netaddr>=0.10.1`
- CLI binaries on the control host: `talosctl`
- Helm on the control host when `talos_proxmox_install_cilium` is enabled (used to render Cilium manifests)
- Proxmox server with API access and the corresponding API key
- Proxmox storage names used in the role (defaults to `truenas-01-isos` for ISOs and `nvme` for VM disks) must exist
- When specifying a starting VMID, the Proxmox API token needs permission to
  list all VMs and containers across the cluster to detect ID and name conflicts

## Talos Versions

The role supports Talos `v1.14.0` and later. Select the target release with
`talos_proxmox_talos_version` and use a matching `talosctl` version on the
control host. The default is `v1.14.5`, and configuration generation
explicitly targets the selected release.

The role uses separate installation, DNS and hostname documents. Control-plane
certificate settings and Cilium's kube-proxy settings are patched only on
master nodes. When `talos_proxmox_schedule_on_masters` is true (the default
when no workers are defined), the control-plane taint and the
`node.kubernetes.io/exclude-from-external-load-balancers` label are also
removed from master nodes, so they can run workloads and load balancers such as
MetalLB (L2) have nodes to announce from. Additional storage uses
`UserVolumeConfig`.

Talos versions older than `v1.14.0` are rejected. Offline configuration
validation covers master/worker, VLAN and Cilium variants; this does not
replace a live cluster installation test.

More documentation:

- [DNS settings and short hostnames](docs/dns-short-hostnames.md)
- [HAProxy on pfSense as a load balancer for the Talos API](docs/haproxy-talos-api.md)

### Official system extensions

Select additional extensions using their `siderolabs/...` names from the
[official extension catalog](https://github.com/siderolabs/extensions#extension-catalog).
Use [Talos Image Factory](https://factory.talos.dev/) to check availability for
your selected Talos version and the role's `amd64` architecture. Do not supply
container image tags or digests in this list. Some extensions need additional
configuration; including them in the image does not configure their services.

The role always includes `siderolabs/qemu-guest-agent`, even when the list is
empty. Proxmox uses the guest agent to discover VM IP addresses before applying
the Talos configuration. Duplicate extensions are included only once.

During installation, the role polls each VM's guest-agent network information
every 10 seconds, with up to 30 retries (about five minutes, plus API request
time). It requires one unique IPv4 address after excluding loopback and
link-local addresses; multiple addresses stop installation rather than selecting
one arbitrarily. This is the ISO's DHCP address, not necessarily the node's
configured static address. Proxmox API failures stop discovery immediately.
Before sending each machine configuration, the role also waits up to 300 seconds
for TCP port `50000` from the host running `talosctl`. An open port confirms
connectivity, not API readiness or node identity. Configuration submission is
not automatically retried.

Longhorn requires `siderolabs/iscsi-tools` and `siderolabs/util-linux-tools`:

```yaml
talos_proxmox_talos_extensions:
  - siderolabs/iscsi-tools
  - siderolabs/util-linux-tools
```

Alternatively, `talos_proxmox_enable_longhorn_support: true` adds those two
extensions automatically, together with the role's existing kernel modules
(`nvme_tcp`, `vfio_pci`) and `vm.nr_hugepages: "1024"` setting. With this switch
enabled, you do not need to list those extensions in
`talos_proxmox_talos_extensions`. Selecting
extensions in the list alone does not enable those node settings. Neither
option installs Longhorn; Longhorn integration remains untested.

The role submits the combined extension list to Image Factory's `/schematics`
API. It combines the returned schematic ID with `talos_proxmox_talos_version`
to generate both the boot ISO URL and the installer image:

```text
https://factory.talos.dev/image/<schematic-id>/<talos-version>/metal-amd64.iso
factory.talos.dev/metal-installer/<schematic-id>:<talos-version>
```

These are generated during configuration, not static defaults. An unavailable
extension/version combination can fail when Image Factory builds the assets;
acceptance of the schematic alone does not prove availability.

The Proxmox ISO filename includes both the Talos version and schematic ID:
`talos-<talos-version>-<schematic-id>-amd64.iso`. Each provisioning run downloads
the ISO and waits up to approximately ten minutes for the returned Proxmox task
to finish with `OK`. Before creating VMs, the role checks that the exact ISO
exists in storage and has a positive size. Download errors, timeouts and missing
or empty files stop the run. The size check is not a checksum or a guarantee of
file integrity.

## Install Requirements

1. Install talosctl: https://docs.siderolabs.com/talos/v1.14/getting-started/talosctl
2. Install python dependencies:

   ```bash
   python -m pip install requests kubernetes PyYAML jsonpatch proxmoxer jmespath 'netaddr>=0.10.1'
   ```
3. Install ansible galaxy dependencies:

   ```bash
   ansible-galaxy collection install community.general community.proxmox kubernetes.core ansible.utils
   ```
4. Install this role

   ```bash
   ansible-galaxy role install git+https://github.com/moskakos/talos_proxmox
   ```

## Sequence

The following sequence describes what the role does in order (if called without any tags):

- Stop if existing Talos or Kubernetes client configuration files are found
- Create talos configuration and patch files
- Create VMs in proxmox
- Install Talos on the VMs by applying the talos configuration; switch to trunk if vlans are enabled
- Bootstrap the talos cluster, wait for the cluster to be ready and get the kube config
- Create all k8s resources defined in "talos_proxmox_static_resources"

Before these steps, the role checks that `talos_proxmox_cluster_name` resolves
on the execution host using its normal system resolver (including hosts-file
entries). This also runs for the `configure_talos`, `create_vms`, `install_talos`,
`bootstrap_cluster` and `deploy_static_resources` tags, including check mode.
Resolution failure stops the run before VM creation. IP literals and empty
strings skip DNS resolution; other validation still requires a valid cluster
name. The result need not equal the cluster VIP, allowing a load-balancer
endpoint. This check does not query Talos nodes' configured DNS servers or
require an already running API.

The protection check runs before provisioning in an untagged installation and
when selecting `bootstrap_cluster`, but not for other tag-only runs. It checks
`~/.talos/config`, `~/.kube/config`, and the target selected by `KUBECONFIG`,
on the host where the role runs. The role stops if any of these files exists:
bootstrap requires new Talos and Kubernetes client configuration files.
Back up and move the existing files to a safe
location before running the role. Preserve both the old and newly generated
configurations when restoring access to other clusters. Only a single
`KUBECONFIG` destination is supported; set a single path or unset the variable
before running the role.

Bootstrap writes a standalone kubeconfig to the checked destination (the
`KUBECONFIG` path, or `~/.kube/config` by default), without merging or forcing
an overwrite. Readiness checks and static resources explicitly use this file
and its current context. Inherited `K8S_AUTH_*` environment settings,
including authentication, context and proxy overrides, are ignored for these
Kubernetes tasks so they cannot select a different cluster.

`deploy_static_resources` can also run separately using an existing kubeconfig,
without moving client configuration files away or repeating bootstrap. Before
readiness checks and resource deployment, the role verifies that the kubeconfig
current context uniquely references the configured Kubernetes API endpoint,
`https://<talos_proxmox_cluster_name>:6443`. A missing file, invalid context or
different endpoint stops the run. This endpoint check does not prove cluster
ownership; use the correct kubeconfig and inventory.

### Persistent Talos configuration

The role stores generated files on the execution host under
`~/.talos/clusters/<talos_proxmox_cluster_name>/`, separately from the
`~/.talos/config` client configuration. Directories use permissions `0700`;
generated files use `0600`. The secrets bundle is reused only from this
cluster's directory; configuration and patch files are regenerated when
`configure_talos` runs. Back up this directory securely for recovery.

These files are retained after installation; there is no automatic cleanup
or `cleanup` tag. `install_talos` and `bootstrap_cluster` tag runs use the same
directory and require the files from a prior `configure_talos` run. File
retention does not make bootstrap repeatable or add support for expanding an
existing cluster. Do not run simultaneous installations for the same cluster.
When rebuilding an unrelated cluster with the same name, archive the previous
directory first to avoid reusing its secrets. Files from the former
`/tmp/.talos` directory are not migrated automatically.

### Optional starting VMID

Set `talos_proxmox_vmid_starting_number` to an integer between 100 and
999999999 to assign consecutive VMIDs, first to masters in inventory order,
then to workers. The entire assigned range must fit within those limits. For
example, a starting value of `200` with three masters and two workers assigns
VMIDs `200` through `204`. The default, `null`, leaves allocation to Proxmox.

Before creating VMs, the role checks cluster-wide VM and container IDs and
names, and checks them again before starting the VMs. A matching existing QEMU
VM on the configured Proxmox node is accepted; any other ID or name conflict
stops the run. A matching name and ID alone do
not prove ownership, so verify existing VMs before running the role. The check
depends on the API token's visibility and is not a reservation: another
process can allocate an ID after the check. Keep the node lists and their order
unchanged when reusing the same starting VMID. Reordering, inserting or removing
nodes can change the calculated assignments and cause conflicts.

## Minimal Example

Create a playbook calling the role:
install_cluster.yml

```yaml
- hosts: localhost
  gather_facts: true
  roles:
    - talos_proxmox
```

Create an inventory that overrites the default values with your needs:
inventory/<env>/group_vars/all.yml

```yaml
talos_proxmox_proxmox_server: "my-proxmox.test.local"
talos_proxmox_proxmox_api_user: "root"
talos_proxmox_proxmox_api_token_id: "my-token-id"
talos_proxmox_proxmox_api_token_secret: "my-token"

talos_proxmox_cluster_name: "k8s.test.local"
talos_proxmox_cluster_shared_ip: 192.168.0.10
talos_proxmox_mgmt_network: "192.168.0.0/24"
talos_proxmox_mgmt_gateway: "192.168.0.1"

talos_proxmox_enable_vlans: false
talos_proxmox_mgmt_vlan_id: false

talos_proxmox_k8s_vmbr: "vmbr0"

talos_proxmox_masters:
  - name: master1
    ip: 192.168.0.11
    cores: 2
    memory: 4096
    disk: 100
  - name: master2
    ip: 192.168.0.12
    cores: 2
    memory: 4096
    disk: 100
  - name: master3
    ip: 192.168.0.13
    cores: 2
    memory: 4096
    disk: 100

talos_proxmox_workers:
  - name: worker1
    ip: 192.168.0.21
    cores: 4
    memory: 8192
    disk: 100
  - name: worker2
    ip: 192.168.0.22
    cores: 4
    memory: 8192
    disk: 100
```

Now run the playbook to install the cluster:

```bash
ansible-playbook -i inventory/<env>/ install_cluster.yml
```

## Tags

You can target specific steps or do other tasks by calling the role with specific tags:
  - `configure_talos`: Create talos configuration and patch files
   - `create_vms`: Create VMs in proxmox
  - `install_talos`: Install Talos on the VMs by applying the talos configuration
  - `bootstrap_cluster`: Bootstrap the talos cluster
   - `deploy_static_resources`: Create all k8s resources defined in "talos_proxmox_static_resources"

## How To

### Port / VLAN Setups

This section describes the different setups for the main interface of the Talos VMs in Proxmox

#### Access Port with no VLAN

```yaml
# Disable vlans to make the role assume an access port
talos_proxmox_enable_vlans: false
# Set the mgmt vlan id to false so that no vlan tag will be set on the proxmox interface
talos_proxmox_mgmt_vlan_id: false
```

### Access Port on specific VLAN

```yaml
# Disable vlans to make the role assume an access port
talos_proxmox_enable_vlans: false
# Set the mgmt vlan id to the target vlan
talos_proxmox_mgmt_vlan_id: 99
```

### Trunk Port with mgmt vlan

Enable this setup explicitly; the default is an access port on VLAN 12.
This will start during the installation with an access port on the provided mgmt vlan and will switch to a trunk port during talos installation.
This configures VLAN interfaces on the Talos nodes and selects them as Cilium devices. It does not add extra network interfaces to pods.

```yaml
# Set talos_proxmox_enable_vlans to true for a trunk port
talos_proxmox_enable_vlans: true
# Set the mgmt vlan id to the target vlan
talos_proxmox_mgmt_vlan_id: 99
```

### Disk Encryption

Disk encryption of the primary disk is not supported by this role. However you can simply configure disk encryption of the secondary disk like this:

```yaml
talos_proxmox_workers:
  - name: worker1
    ip: 192.168.0.21
    cores: 4
    memory: 8192
    disk: 100
    storage_disk: 200 # Define a secondary disk
    storage_disk_encryption_key: "my-secret-key" # Define an encryption key
```

### Static resource templates

Each `talos_proxmox_static_resources` item must specify exactly one source:
an inline `definition` dictionary or a `src` file. Set the boolean
`template: true` to render a `src` file as Jinja2 before applying it:

```yaml
talos_proxmox_static_resources:
  - src: manifests/example.yaml.j2
    template: true
```

Templates must be available on the Ansible controller. With `template: false`
or without the field, `src` is applied as an ordinary YAML file. Inline
`definition` dictionaries continue to work without a file.

## Variables

### Proxmox certificate authority

For a Proxmox API certificate issued by a private PKI, configure a PEM CA
bundle on the host executing the Ansible modules (localhost in the example):

```yaml
talos_proxmox_proxmox_ca_path: /polku/pki-root-ca.pem
```

An empty value (the default) omits `ca_path` and uses the modules' default CA
trust. The Proxmox API hostname must match the server certificate.

The Proxmox ISO download and storage polling requests also validate TLS
certificates and use this CA bundle. Private PKI installations that previously
relied on those requests skipping validation must configure a trusted CA.
Storage polling reports connection and certificate errors rather than ignoring
them.

All role variables use the `talos_proxmox_` prefix. Update existing inventory,
group_vars, host_vars and extra_vars overrides to the new names; old names are
no longer supported. The prefix is added to the complete previous name, for
example `proxmox_server` becomes `talos_proxmox_proxmox_server`.

The following table lists role variables (from `defaults/main.yml`), their default values, and a short description.

### Integration testing status

Cilium, Gateway API, WireGuard pod and node encryption, VLAN device selection,
and Longhorn prerequisites are implemented
but have not been integration-tested by the maintainer. The related variables
are marked **Integration untested** below. Offline rendering and configuration
validation do not establish that these features work in a running cluster.

Enabling Cilium also enables Gateway API and WireGuard by default unless their
settings are overridden. Longhorn support adds system extensions and node
settings only; the role does not install Longhorn.

### Variable reference

| Variable | Default | Description |
|---|---|---|
| `talos_proxmox_proxmox_server` | `pve-01.example.com` | Hostname or IP of the Proxmox server |
| `talos_proxmox_proxmox_port` | `8006` | Proxmox API port |
| `talos_proxmox_proxmox_ca_path` | `""` | Optional PEM CA bundle path on the module execution host |
| `talos_proxmox_proxmox_url` | `https://{{ talos_proxmox_proxmox_server }}:{{ talos_proxmox_proxmox_port }}` | Base Proxmox URL (derived) |
| `talos_proxmox_proxmox_api_url` | `{{ talos_proxmox_proxmox_url }}/api2/json` | Full Proxmox API base URL (derived) |
| `talos_proxmox_proxmox_api_user` | `talos@pve` | Proxmox API user for token authentication |
| `talos_proxmox_proxmox_api_token_id` | `token` | Proxmox API token id (use real token in inventory) |
| `talos_proxmox_proxmox_api_token_secret` | `secret` | Proxmox API token secret (use real secret in inventory) |
| `talos_proxmox_proxmox_node` | `pve-01` | Proxmox cluster node to create VMs on |
| `talos_proxmox_proxmox_storage` | `truenas-01-isos` | Proxmox storage name for ISOs/templates |
| `talos_proxmox_proxmox_vm_storage` | `nvme` | Proxmox storage target for VM disks |
| `talos_proxmox_vmid_starting_number` | `null` | Optional first VMID; assigns consecutive IDs to masters, then workers |
| `talos_proxmox_proxmox_storage_url` | `{{ talos_proxmox_proxmox_api_url }}/nodes/{{ talos_proxmox_proxmox_node }}/storage/{{ talos_proxmox_proxmox_storage }}` | Proxmox storage API URL (derived) |
| `talos_proxmox_talos_version` | `v1.14.5` | Talos release version to download/install (minimum supported: `v1.14.0`) |
| `talos_proxmox_talos_api_cert_sans` | `[]` | Optional extra Talos API certificate DNS names or IP addresses on control-plane nodes; see the [HAProxy guide](docs/haproxy-talos-api.md) |
| `talos_proxmox_talos_extensions` | `[]` | Additional official system extensions; QEMU guest agent is always included. See [extension configuration](#official-system-extensions) |
| `talos_proxmox_enable_longhorn_support` | `false` | **Integration untested.** Automatically include `siderolabs/iscsi-tools`, `siderolabs/util-linux-tools` and kernel/sysctl prerequisites; does not install Longhorn |
| `talos_proxmox_talos_installation_disk_path` | `/dev/sda` | Disk device inside VM where Talos will be installed |
| `talos_proxmox_talos_cpu_type` | `host` | CPU type to pass to Proxmox VM definition |
| `talos_proxmox_cluster_name` | `kube.example.com` | Cluster name used in Talos configs |
| `talos_proxmox_cluster_shared_ip` | `192.168.1.20` | Shared/virtual IP for control-plane services |
| `talos_proxmox_mgmt_network` | `192.168.1.0/24` | IPv4 management network in CIDR notation; supplies the address prefix length for both access and VLAN interfaces |
| `talos_proxmox_mgmt_gateway` | `192.168.1.254` | Default gateway for management network |
| `talos_proxmox_enable_vlans` | `false` | Enable VLAN-aware VM/network configuration (requires Cilium) |
| `talos_proxmox_mgmt_vlan_id` | `12` | VLAN ID for the management sub-interface in trunk mode or the Proxmox VM interface in access mode |
| `talos_proxmox_install_cilium` | Same as `talos_proxmox_enable_vlans` | **Integration untested.** Install Cilium instead of Flannel |
| `talos_proxmox_cilium_version` | `1.18.2` | **Integration untested.** Cilium Helm chart version |
| `talos_proxmox_enable_gateway_api` | Same as `talos_proxmox_install_cilium` | **Integration untested.** Enable Cilium Gateway API and install its CRDs; requires Cilium |
| `talos_proxmox_gateway_api_crds_version` | `v1.2.0` | **Integration untested.** Gateway API CRD release |
| `talos_proxmox_gateway_api_crds_base_url` | `https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/{{ talos_proxmox_gateway_api_crds_version }}/config/crd` | **Integration untested.** Base URL for Gateway API CRDs |
| `talos_proxmox_gateway_api_crds` | See file | **Integration untested.** CRD definitions with `type` and `name` |
| `talos_proxmox_enable_cilium_wireguard` | Same as `talos_proxmox_install_cilium` | **Integration untested.** Enable WireGuard pod traffic encryption |
| `talos_proxmox_enable_cilium_node_encryption` | `false` | **Integration untested.** Also encrypt node traffic; requires Cilium and WireGuard |
| `talos_proxmox_vlan_base_interface` | `eth0` | **Integration untested.** Base interface name used to select Cilium VLAN devices; must match the node interface |
| `talos_proxmox_k8s_vmbr` | `vmbr0` | Proxmox bridge used for VM network interfaces |
| `talos_proxmox_masters` | See file | List of master VM definitions (name, ip, cores, memory, disk) |
| `talos_proxmox_workers` | `[]` | List of worker VM definitions (may include `storage_disk`) |
| `talos_proxmox_schedule_on_masters` | `true` if no workers, else `false` | Allow workloads on master nodes (removes the control-plane taint and load balancer exclusion label) |
| `talos_proxmox_vlan_config` | See file | **Integration untested.** Additional VLAN definitions for Talos node interfaces and Cilium devices |
| `talos_proxmox_nameservers` | `[192.168.1.1, 192.168.1.2]` | DNS servers rendered into Talos configs |
| `talos_proxmox_search_domains` | `[example.com, internal.example.com]` | Search domains rendered into `ResolverConfig` (empty means not set) |
| `talos_proxmox_host_dns` | `{enabled: true, forwardKubeDNSToHost: true, resolveMemberNames: true}` | Optional `hostDNS` settings rendered into `ResolverConfig` (empty means not set) |
| `talos_proxmox_timeservers` | `[time.example.com]` | NTP/time servers for Talos configs |
| `talos_proxmox_disable_ipv6` | `true` when VLANs disabled, else `false` | Disable IPv6 in rendered Talos configs if true |
| `talos_proxmox_static_resources` | `[]` | List of k8s resources to apply after cluster creation (see file) |

## License
MIT
