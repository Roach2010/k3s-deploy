# Deploying k3s on Fedora CoreOS via VMware vSphere (`govc`)

This repository provides an automated pipeline to spin up a lightweight, production-grade Kubernetes cluster using **k3s** on **Fedora CoreOS (FCOS)** nodes running inside VMware ESXi/vSphere. 

If you already know your way around Linux (`systemctl`, `journalctl`, system networking, and shell scripting) but are stepping into Kubernetes for the first time, this guide will walk you through how the infrastructure works under the hood, how to deploy your first cluster, and how to operate it.

---

## 1. Core Architecture & Concepts

Before running scripts, it helps to understand what is happening under the hood. Kubernetes is a distributed system, and this repository automates the OS-level provisioning and node bootstrapping.

```
+-----------------------------------------------------------------------------------+
|                                Host Environment                                   |
|                                                                                   |
|   +-------------------+   +--------------------+   +--------------------------+   |
|   |   deploy.env      |   |  Butane Templates  |   | CoreOS Stream API        |   |
|   | (Secrets/Config)  |   |    (.bu files)     |   | (Fetches latest FCOS)    |   |
|   +---------+---------+   +---------+----------+   +------------+-------------+   |
|             |                       |                           |                 |
|             +-----------+-----------+                           |                 |
|                         |                                       |                 |
|                         v                                       v                 |
|              [ Render Ignition JSON ]                   [ Cache FCOS OVA ]        |
|                         |                                       |                 |
|                         +-------------------+-------------------+                 |
|                                             |                                     |
|                                             v                                     |
|                                   [ govc Import Pipeline ]                        |
+---------------------------------------------+-------------------------------------+
                                              |
                                              v
+-----------------------------------------------------------------------------------+
|                                 VMware vSphere                                    |
|                                                                                   |
|  +------------------------------------++---------------------------------------+  |
|  |       Control-Plane Node(s)        ||             Worker Node(s)            |  |
|  |                                    ||                                       |  |
|  | 1. Bootstraps via Ignition         || 1. Bootstraps via Ignition            |  |
|  | 2. Layers `open-vm-tools`          || 2. Layers `open-vm-tools`             |  |
|  | 3. Runs `k3s server`               || 3. Runs `k3s agent` (Kubelet)         |  |
|  | 4. Serves Kubernetes API (6443)    || 4. Joins Control-Plane via API Token  |  |
|  +------------------------------------++---------------------------------------+  |
+-----------------------------------------------------------------------------------+
```

### Key Components

*   **Fedora CoreOS (FCOS)**: An immutable, minimal host operating system optimized for running containerized workloads. It uses `rpm-ostree` instead of traditional package managers like `dnf` or `apt`.
*   **Ignition & Butane**: FCOS does not use traditional installers or Cloud-Init. Instead, **Ignition** reads a JSON configuration file on *first boot only* to write files, systemd units, and SSH keys. **Butane** is the human-readable YAML tool used to compile these Ignition JSON files.
*   **`govc`**: The official VMware CLI tool used to communicate with vCenter/ESXi to import virtual machines, attach NICs, assign datastores, and inject Ignition metadata into `guestinfo`.
*   **k3s**: A lightweight Kubernetes distribution packaged as a single binary. 
    *   **Control Plane (`k3s server`)**: Hosts the API server, scheduler, controller manager, and datastore (SQLite or Etcd).
    *   **Worker (`k3s agent`)**: Runs the `kubelet` and container runtime to execute your workload containers.

---

## 2. Directory Structure

```
.
├── fcos-k3s-controlplane.bu   # Butane YAML template for the Control Plane node
├── fcos-k3s-worker.bu         # Butane YAML template for Worker nodes
├── deploy-controlplane.sh     # Self-contained deployment script for Control Plane
├── deploy-worker.sh           # Self-contained deployment script for Workers
├── inject-controlplane.sh     # Injects Ignition into an existing Control Plane VM (no import)
├── inject-worker.sh           # Injects Ignition into an existing Worker VM (no import)
├── deploy.env.example         # Template for cluster configuration and credentials
├── manifests/
│   └── nfs-csi/
│       ├── base/               # Generic StorageClass (safe to commit)
│       ├── overlay.example/    # Template patch - copy to overlay/ and edit
│       ├── overlay/            # Your real NFS server details (Git-ignored)
│       └── examples/           # Standalone PVC/PV examples, copy per workload
├── .gitignore                 # Prevents secrets, cache, and rendered output from hitting Git
├── rendered/                  # Transient output directory for compiled .ign files (Git-ignored)
└── ova/                       # Local cache directory for downloaded FCOS binaries (Git-ignored)
```

---

## 3. Prerequisites & Local Environment

Ensure you have the following command-line utilities installed on your workstation:

1.  **`govc`**: VMware CLI (`go install github.com/vmware/govmomi/govc@latest` or install via system package manager).
2.  **`butane`**: CoreOS configuration compiler.
3.  **`jq`**: Command-line JSON processor.
4.  **`curl`**: Standard transfer tool used to fetch CoreOS release metadata.

### Infrastructure Requirements
*   An active vCenter account with permissions to deploy VMs and access Datastores.
*   A vSphere Portgroup with **DHCP enabled** (you can assign static DHCP reservations via MAC address during deployment).
*   An SSH key pair for accessing your nodes.

---

## 4. Configuration Step-by-Step

Start by copying the example configuration environment file:

```bash
cp deploy.env.example deploy.env
```

Open `deploy.env` in your text editor and configure your environment settings:

| Variable | Description |
| :--- | :--- |
| `GOVC_URL` | vCenter hostname or IP address. |
| `GOVC_USERNAME` | vCenter administrator or provisioning user. |
| `GOVC_PASSWORD` | vCenter password. |
| `GOVC_INSECURE` | Set to `true` if your vCenter uses a self-signed TLS certificate. |
| `DS_CLUSTER` | Name of your vSphere Datastore Cluster / StoragePod. |
| `NETWORK` | vSphere Portgroup to attach the node NIC. |
| `FCOS_STREAM` | Release channel (`stable`, `testing`, or `next`). Defaults to `stable`. |
| `FCOS_OVA` | *(Optional)* Absolute path to an OVA file on disk if you want to bypass dynamic downloads. |
| `VM_FOLDER` | vCenter VM inventory folder path (e.g., `/Datacenter/vm/k3s`). |
| `DOMAIN_SUFFIX` | Domain name appended to hostnames (e.g., `cluster.local`). |
| `SSH_PUBLIC_KEY_1` | Your SSH public key (added to the `core` user on the node). |
| `K3S_TOKEN` | A secret shared key you create for joining nodes to the cluster. |
| `CP1_IP` | IP of control-plane node 1. |
| `CP1_NAME` | Hostname for control-plane node 1 (`DOMAIN_SUFFIX` is appended automatically). |
| `CP2_IP` | IP of control-plane node 2. |
| `CP2_NAME` | Hostname for control-plane node 2. |
| `CP3_IP` | IP of control-plane node 3. |
| `CP3_NAME` | Hostname for control-plane node 3. |
| `KUBE_API_HOSTNAME` | Shared API DNS name: one A record pointing to `KUBE_VIP`. |
| `KUBE_VIP` | Unused API virtual IP, default `192.168.60.10`. Exclude it from DHCP. |
| `KUBE_VIP_INTERFACE` | NIC on every control-plane VM that shares the VIP subnet; verify with `ip -br link`. |
| `KUBE_VIP_VERSION` | Pinned kube-vip image tag, default `v1.2.4`. |
| `EXTRA_TLS_SAN` | *(Optional)* Extra IPs or hostnames to include in the API server TLS certificate. |
| `K3S_VERSION` | Exact release tag of k3s (e.g., `v1.30.4+k3s1`). |
| `CLUSTER_CIDR` | Internal IP space reserved for Pods (e.g., `10.42.0.0/16`). |
| `SERVICE_CIDR` | Internal IP space reserved for Services (e.g., `10.43.0.0/16`). |
| `NFS_CSI_DRIVER_VERSION` | Version tag of `csi-driver-nfs` to install (e.g., `v4.13.0`). See [NFS Storage](#setting-up-nfs-storage-csi-driver-nfs) below. |

Make the deployment scripts executable:

```bash
chmod +x deploy-controlplane.sh deploy-worker.sh
```

---

## 5. Deploying the Cluster

### Step 1: Deploy the First Control Plane Node

Run the control plane deploy script with your desired VM host name:

```bash
./deploy-controlplane.sh k3s-cp1 --cluster-init
```

#### Handling DHCP Reservations (`--wait-for-reservation`, `--node`)
If you want to pin a control-plane node's IP in your DHCP server before
it boots for the first time, use the `-w`/`--wait-for-reservation` flag.
When deploying node 2 or 3, also pass `-n`/`--node <1|2|3>` so the script
suggests the *correct* IP for that specific node (`CP1_IP`,
`CP2_IP`, or `CP3_IP`) instead of always assuming node 1:

```bash
./deploy-controlplane.sh k3s-cp1 --cluster-init --wait-for-reservation
./deploy-controlplane.sh k3s-cp2 --join --wait-for-reservation --node 2
./deploy-controlplane.sh k3s-cp3 --join --wait-for-reservation --node 3
```

The script will configure the vSphere VM, print its generated **MAC Address** alongside the IP to reserve for it, and pause. You can then add the MAC-to-IP reservation in your router or DHCP server before pressing **Enter** to power on the VM.

Worker nodes are always plain DHCP with no fixed-IP option - `deploy-worker.sh` doesn't have a `--wait-for-reservation` flag.

### Step 2: High Availability Control Plane and API failover

By default, k3s uses an embedded SQLite database suitable for single control-plane setups. If you want a High Availability (HA) control plane with multiple API nodes, k3s uses an embedded **Etcd** cluster instead.

1.  **Initialize the HA cluster on node 1**:
    ```bash
    ./deploy-controlplane.sh k3s-cp1 --cluster-init
    ```
2.  **Join additional control plane nodes**:
    ```bash
    ./deploy-controlplane.sh k3s-cp2 --join --node 2
    ./deploy-controlplane.sh k3s-cp3 --join --node 3
    ```
    Wait for node 1 to finish its automatic reboot and for the VIP API to
    become reachable before joining node 2. Wait for node 2 to finish its
    reboot and become Ready before joining node 3. Both join through
    `https://<KUBE_VIP>:6443`. Deploy node 1 only once, with `--cluster-init`;
    this step describes the same first deployment as Step 1.

Every control-plane node's certificate covers all three nodes' IPs and
DNS names, plus `KUBE_API_HOSTNAME` and `KUBE_VIP` - so `kubectl` or a worker can reach
any node directly, or via the shared name, without a TLS error.

#### Making the API Reachable if a Node Goes Down (`KUBE_API_HOSTNAME`)

Ignition writes kube-vip RBAC and an ARP-mode DaemonSet to
`/var/lib/rancher/k3s/server/manifests/kube-vip.yaml` on every server.
K3s applies it automatically; kube-vip runs only on control-plane nodes.
One elected node owns `192.168.60.10`. If it fails, another advertises the
same IP. Existing connections may need to reconnect during election.
This provides automatic failover, without distributing API connections
across all servers. Service load balancing is disabled in kube-vip;
the existing K3s ServiceLB configuration is unchanged.

Before deployment:

* Reserve `192.168.60.10` outside the DHCP pool; do not assign it to a VM
  or a DHCP reservation. Keep each VM's individual IP reservation.
* Put all control-plane NICs on the same layer-2 VLAN/subnet as the VIP.
  The network must permit gratuitous ARP and traffic to TCP 6443.
* Set `KUBE_VIP_INTERFACE` to the actual NIC name shared by the VMs.
  `ens192` in the example is not auto-detected. Bootstrap fails clearly
  if that interface does not exist.
* Create **one** DNS A record: `KUBE_API_HOSTNAME` -> `192.168.60.10`.
  Remove any old round-robin records for that name.

The DaemonSet authenticates with its ServiceAccount against each node's
local API (`127.0.0.1:6443`), so acquiring the VIP does not require the
VIP to be up. Keep the rendered manifest identical on every server.
Workers and the user's kubeconfig continue using `KUBE_API_HOSTNAME`.

After node 1 reboots, inspect startup over its individual IP:

```bash
ssh core@192.168.60.11
sudo k3s kubectl -n kube-system rollout status daemonset/kube-vip-ds --timeout=180s
sudo k3s kubectl --server=https://192.168.60.10:6443 get --raw=/readyz
```

After all **three** etcd servers have finished bootstrapping and are Ready,
verify failover from a separate workstation using the copied kubeconfig:

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods -l app=kube-vip -o wide
kubectl -n kube-system get leases
```

Identify the VIP owner with `ip -4 addr show dev <interface>` on each
server. Power off only that VM, then repeat `kubectl get nodes` through
the shared endpoint until it succeeds. Confirm the VIP moved to another
server, restore the VM, and wait for all three nodes to become Ready.
Do not test node failure while only one or two etcd servers exist: quorum
cannot tolerate losing a member. A single-node SQLite deployment remains
possible without `--cluster-init`, but has no node-failure tolerance.

References: [kube-vip on K3s](https://kube-vip.io/docs/usage/k3s/),
[ARP DaemonSet](https://kube-vip.io/docs/installation/daemonset/).

### Step 3: Deploy Worker Nodes

Worker nodes run workloads and report back to the control plane. Pass a unique hostname for each worker:

```bash
./deploy-worker.sh k3s-worker1
./deploy-worker.sh k3s-worker2
```

### Re-injecting Config Into an Already-Existing VM

`inject-controlplane.sh` and `inject-worker.sh` do the same Butane
rendering and Ignition compilation as the two scripts above, but skip
every VM-*creation* step - no datastore selection, no import spec, no
`govc import.ova`. Use these when the VM already exists in vSphere (e.g.
you imported it some other way) and you just need to (re-)inject its
Ignition config:

```bash
./inject-controlplane.sh k3s-cp1 --cluster-init
./inject-worker.sh k3s-worker1
```

They take the same role-specific flags as their `deploy-*.sh`
counterparts (`--cluster-init`/`-c`, `--join`/`-j`, `--node`/`-n`,
`--wait-for-reservation`/`-w` for control-plane; none for workers), plus
one new one: `--power-on`/`-p`. **Neither script powers the VM on by
default** - injection only, unless you pass that flag.

**This only does something useful if the VM has never been powered on
before.** Ignition runs once, during a VM's very first boot - it is not
a configuration-management tool that reapplies on every reboot. Injecting
new `guestinfo` into a VM that's already completed its first boot (even
if you then reboot it) will not retroactively apply the new config; you'd
need to re-import a fresh VM instead. Both scripts print a reminder of
this after injecting.

---

## 6. Accessing and Operating the Cluster

When a host boots for the first time, Ignition executes the following sequence:
1. Formats disk partitions, writes SSH keys, and generates system config.
2. Runs a systemd setup unit that installs `k3s`.
3. Runs `rpm-ostree install open-vm-tools` to add VMware drivers to the base FCOS image.
4. Generates a user-accessible `kubeconfig` file at `/home/core/.kube/config`.
5. On the node that creates the cluster (single-node deploy, or `--cluster-init`) only: installs `csi-driver-nfs` against the running API server. `--join` nodes skip this step.
6. Initiates an automated system reboot to finalize the `rpm-ostree` driver layer.

### Connecting to the Cluster with `kubectl`

Once the primary control plane node finishes its final reboot, log into the machine via SSH:

```bash
ssh core@<CP1_IP>
```

You can execute `kubectl` commands immediately on the machine:

```bash
kubectl get nodes
```

To manage the cluster from your local workstation, copy the generated `kubeconfig` file off the host:

```bash
# Copy the config to your local machine
scp core@<CP1_IP>:.kube/config ./kubeconfig

# Point your local environment to the file
export KUBECONFIG=$(pwd)/kubeconfig

# Test connection
kubectl get nodes -o wide
```

> **Why check `/home/core/.kube/config` instead of `/etc/rancher/k3s/k3s.yaml`?**
> The system file at `/etc/rancher/k3s/k3s.yaml` is k3s's internal admin configuration. k3s automatically overwrites this file on every service restart to point to `127.0.0.1:6443`. To protect user settings, our deployment script creates a separate one-time copy in `/home/core/.kube/config` mapped to `KUBE_API_HOSTNAME`.

### Setting Up NFS Storage (`csi-driver-nfs`)

The cluster-creating control-plane node automatically installs
[`csi-driver-nfs`](https://github.com/kubernetes-csi/csi-driver-nfs)
(version `NFS_CSI_DRIVER_VERSION`). That gets you the CSI driver itself -
it does **not** create a `StorageClass`, since this toolkit has no way to
know your actual NFS server's address or export path.

Confirm the driver installed:

```bash
kubectl get pods -n kube-system -l app=csi-nfs-controller
kubectl get pods -n kube-system -l app=csi-nfs-node
```

#### Creating the `StorageClass` (Kustomize)

The `StorageClass` lives under `manifests/nfs-csi/` as a Kustomize base
plus an example overlay - the same `.example` pattern `deploy.env.example`
uses: the base is generic and safe to commit, the real overlay (with your
actual NAS address) is gitignored.

```bash
cp -r manifests/nfs-csi/overlay.example manifests/nfs-csi/overlay
```

Edit `manifests/nfs-csi/overlay/storageclass-patch.yaml`, filling in your
own `server` and `share` (the mount options are already tuned for
Synology DSM - `nfsvers=4.1` since DSM doesn't support 4.2):

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi
parameters:
  server: <your-nas-ip-or-hostname>
  share: <path-to-your-nfs-export>
mountOptions:
  - nfsvers=4.1
  - nconnect=4
  - rsize=1048576
  - wsize=1048576
  - noatime
  - hard
  - timeo=600
```

Then apply it:

```bash
kubectl apply -k manifests/nfs-csi/overlay/
```

NFSv4.1 needs to be enabled on the NAS side too (on Synology DSM: Control
Panel → File Services → NFS).

#### Creating a PersistentVolumeClaim

There are two ways to actually consume storage, matching
`csi-driver-nfs`'s own terminology for them. Example files for both are
under `manifests/nfs-csi/examples/` - copy and edit per workload, these
aren't part of the Kustomize setup above since PVCs are one-off rather
than environment config.

**Dynamic provisioning** (`examples/pvc-dynamic.yaml`) - let the driver
create a new subdirectory under your `share` path automatically, one per
`PersistentVolumeClaim`. Simplest option, and what most workloads should
use - no `PersistentVolume` needed, just a PVC referencing the
`StorageClass` above:

```bash
kubectl apply -f manifests/nfs-csi/examples/pvc-dynamic.yaml
```

**Static provisioning** (`examples/pv-static.yaml` +
`examples/pvc-static.yaml`) - bind to one *specific*, already-existing
folder on your NAS instead of letting the driver create a new one. Use
this when you have an existing folder structure you want a workload to
reuse. Edit the `server`/`share`/`volumeHandle` placeholders in
`pv-static.yaml` first, following the
[driver's own static provisioning example](https://github.com/kubernetes-csi/csi-driver-nfs/blob/master/deploy/example/README.md#pvpvc-usage-static-provisioning),
then apply both:

```bash
kubectl apply -f manifests/nfs-csi/examples/pv-static.yaml
kubectl apply -f manifests/nfs-csi/examples/pvc-static.yaml
kubectl get pv,pvc
```

`STATUS` should read `Bound` for both once the claim picks up the volume.

---

## 7. Deep Dive & Troubleshooting

Because CoreOS uses `systemd` and standard Linux primitives, troubleshooting is straightforward.

### Monitoring First-Boot Initialization
If you want to watch the node setup live, open the VM Console in vCenter immediately after deployment. The installation units write progress logs directly to the virtual console using standard systemd output formatting (`StandardOutput=journal+console`).

If a host appears stuck during provisioning, log into the host via SSH or console and inspect the installer service unit logs:

```bash
# Inspect control plane installation logs
journalctl -u k3s-server-install.service -f

# Inspect worker node installation logs
journalctl -u k3s-agent-install.service -f
```

### Common Gotchas

*   **`kubectl` cannot connect to `KUBE_API_HOSTNAME`**: Confirm its single A record resolves to `KUBE_VIP`. Connect over an individual node IP and inspect `sudo k3s kubectl -n kube-system logs -l app=kube-vip --tail=100`, the configured NIC, and the VIP lease. Verify etcd quorum and same-VLAN connectivity.
*   **Token security**: The cluster token is saved on the node under `/etc/rancher/k3s/token` with restricted permissions (`0600`). This prevents sensitive tokens from leaking into process listings (`ps aux`).
*   **FCOS Updates & Layering**: Fedora CoreOS updates automatically over time. Custom additions like `open-vm-tools` are layered on top of the underlying OS image via `rpm-ostree`. You can view current OS tree status using:
    ```bash
    rpm-ostree status
    ```
