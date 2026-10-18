# Deploying k3s on Fedora CoreOS via VMware vSphere (`govc`)

This repository provides an automated pipeline to spin up a lightweight, production-grade Kubernetes cluster using **k3s** on **Fedora CoreOS (FCOS)** nodes running inside VMware ESXi/vSphere. 

If you already know your way around Linux (`systemctl`, `journalctl`, system networking, and shell scripting) but are stepping into Kubernetes for the first time, this guide will walk you through how the infrastructure works under the hood, how to deploy your first cluster, and how to operate it.

---

## 1. Core Architecture & Concepts

Before running scripts, it helps to understand what is happening under the hood. Kubernetes is a distributed system, and this repository automates the OS-level provisioning and node bootstrapping. Once the nodes are ready, Ansible installs the cluster services: MetalLB, the Synology and NFS CSI drivers, cert-manager, the Cloudflare API token Secret, and Let's Encrypt ClusterIssuers. Separate application playbooks deploy workloads such as Emby after those services are ready.

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
*   **Ansible**: Runs on your management machine and configures cluster services through the Kubernetes API. Butane/Ignition manages the nodes; Ansible manages the Synology and NFS CSI Kubernetes resources after node provisioning.

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
├── ansible/
│   ├── ansible.cfg            # Local inventory, role paths, and Vault password file
│   ├── requirements.yml       # Required Ansible collections
│   ├── inventory/
│   │   ├── hosts.yml          # Runs cluster management tasks on localhost
│   │   └── group_vars/all/    # Cluster variables and encrypted Vault secrets
│   ├── playbooks/
│   │   ├── bootstrap-cluster.yml # Installs cluster services
│   │   ├── test-kubernetes.yml
│   │   └── applications/
│   │       ├── emby.yml      # Emby application deployment
│   │       └── headscale.yml  # Headscale application deployment
│   └── roles/
│       ├── synology_csi/      # Synology SAN Manager iSCSI CSI driver
│       ├── nfs_csi/           # Versioned NFS CSI manifests and readiness checks
│       ├── cert_manager/      # cert-manager Helm release
│       ├── cloudflare/        # Cloudflare API token Secret
│       ├── cluster_issuer/    # Let's Encrypt staging and production issuers
│       ├── certificate_test/
│       ├── emby/             # StatefulSet, iSCSI config, NFS media, and local HTTPS
│       └── headscale/         # Headscale, persistent data, and HTTPS proxy
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

For cluster bootstrap, your Ansible management machine also needs **Python 3.11+**, **Ansible Core 2.19**, **Helm 3**, and **`kubectl`**. In your Ansible Python environment, install the Kubernetes client dependencies and the repository's collection requirements:

```bash
python -m pip install kubernetes PyYAML jsonpatch
cd ansible
ansible-galaxy collection install -r requirements.yml
```

For more reliable change detection in Helm tasks, install the Helm diff plugin as the same user who runs Ansible:

```bash
helm plugin install https://github.com/databus23/helm-diff
helm diff version
```

If it is already installed, use `helm plugin update diff`. Helm is used for cert-manager; the NFS CSI role applies Kubernetes manifests directly.

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
| `WORKER_CPUS` | Optional default worker vCPU count; blank preserves the OVA default. |
| `WORKER_MEMORY_MB` | Optional default worker memory in MiB; blank preserves the OVA default. |
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

Cluster service settings live separately in `ansible/inventory/group_vars/all/vars.yml`:

| Variable | Description |
| :--- | :--- |
| `kubeconfig` | Path to the Kubernetes credentials on the Ansible machine. Defaults to `~/.kube/config`. |
| `domain` | DNS zone used for certificate requests. |
| `letsencrypt_email` | Contact email for the Let's Encrypt accounts. |
| `nfs_csi_wait_timeout` | Optional override of the driver readiness timeout, currently 300 seconds per resource. |
| `synology_csi_dsm_host` | Synology DSM address used by SAN Manager, currently `192.168.20.5`. |
| `synology_csi_dsm_username` | Dedicated DSM user for CSI; keep its password in encrypted `vault.yml`. |
| `synology_csi_storage_location` | DSM volume for dynamically provisioned iSCSI LUNs, currently `/volume1`. |

Keep `vault_cloudflare_api_token` in the encrypted `ansible/inventory/group_vars/all/vault.yml`. The Ansible configuration reads the Vault password from `~/.ansible/.vault_pass`.

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

#### Choosing Worker CPU and Memory Sizes

Set shared worker defaults in `deploy.env`, for example:

```bash
WORKER_CPUS='4'
WORKER_MEMORY_MB='8192'
```

These settings give new workers 4 vCPUs and 8 GiB of memory. Override either
setting for an individual worker on the command line:

```bash
./deploy-worker.sh k3s-worker1
./deploy-worker.sh k3s-worker2 --cpus 8 --memory-mb 16384
```

Command-line values take precedence over `deploy.env`. Values must be
positive integers; memory uses MiB, so 16384 means 16 GiB. Leave either
configuration variable blank to retain that resource's OVA default.
The script validates sizing before downloading or importing the OVA, then
applies it with `govc vm.change` while the imported VM is powered off.

These options apply to new worker VMs. They do not resize existing nodes or
change control-plane sizing. `inject-worker.sh` only injects configuration;
size an existing VM separately in vSphere before booting it.

After a worker joins, inspect the resources reported to Kubernetes:

```bash
kubectl describe node <worker-fqdn>
```

The `Capacity` and `Allocatable` sections show the node's resources and the
portion available for scheduling. Pod resource requests and limits are
configured separately in application manifests.

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

They take the cluster bootstrap flags from their `deploy-*.sh`
counterparts (`--cluster-init`/`-c`, `--join`/`-j`, `--node`/`-n`,
`--wait-for-reservation`/`-w` for control-plane; no cluster-init/join flags for workers), plus
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

When a host boots for the first time, Ignition and the systemd setup unit perform the following sequence:
1. Ignition writes SSH keys, configuration files, and the setup unit.
2. The setup unit runs `rpm-ostree install -y open-vm-tools` if VMware tools are not already present.
3. Installs and starts `k3s server` or `k3s agent`. On servers, K3s also applies the kube-vip manifest written by Ignition.
4. On control-plane nodes, generates a user-accessible `kubeconfig` file at `/home/core/.kube/config`.
5. Marks node bootstrap complete and initiates an automated system reboot to finalize the package layer.

After the nodes finish rebooting, run the Ansible cluster bootstrap below. NFS CSI installation is no longer part of the first-boot script.

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

The Ansible `nfs_csi` role installs
[`csi-driver-nfs`](https://github.com/kubernetes-csi/csi-driver-nfs)
after the nodes are ready. It applies the pinned upstream RBAC, CSIDriver,
controller Deployment, and node DaemonSet manifests. The driver runs in
`kube-system` and registers as `nfs.csi.k8s.io`. It does **not** create a
`StorageClass`, NAS exports, or application PVs/PVCs.

The existing FCOS host NFS support stays in place. This migration needs no
additional package layering or host NFS mount units in either Butane template.
The driver image includes its own NFS client utilities, and its privileged
node plugin shares mounts with the host's `/var/lib/kubelet/pods` directory.
Nodes still need kernel NFS support and network access to the NAS.

From the repository root, first confirm the nodes are ready, then run the
cluster bootstrap:

```bash
kubectl get nodes -o wide
cd ansible
ansible-playbook playbooks/bootstrap-cluster.yml --syntax-check
ansible-playbook playbooks/bootstrap-cluster.yml
```

Before running Ansible, set `kubeconfig` in `inventory/group_vars/all/vars.yml`
to your credentials file. Its default is `~/.kube/config`; exporting
`KUBECONFIG` for `kubectl` above does not override this explicit Ansible variable.
Run the playbook from `ansible/` so its configuration, inventory, and role
paths are used.

Bootstrap runs `metallb`, `synology_csi`, `nfs_csi`, `cert_manager`,
`cloudflare`, and `cluster_issuer` in that order. The NFS role uses `kubernetes.core.k8s` with `apply: true`,
so repeated runs reconcile the same objects. It waits up to 300 seconds each
for the controller Deployment and node DaemonSet, then checks the driver
registration. Failed applies or readiness timeouts stop the playbook.
Readiness and registration checks are skipped in Ansible check mode.

To run only the NFS role, from the same directory:

```bash
ansible-playbook playbooks/bootstrap-cluster.yml --tags nfs_csi
```

The default version is `v4.13.4`, configured in
`roles/nfs_csi/defaults/main.yml`, matching the existing cluster installation.
This transfers management to Ansible without changing the driver version.
Keep the existing driver and PVs/PVCs in place; this handover does not require
uninstalling them or adopting a Helm release. Existing nodes do not need to
rerun Ignition. Set future version changes through `nfs_csi_version` in
`roles/nfs_csi/defaults/main.yml`. Keep each role's version pin in its own
defaults file rather than duplicating it in inventory variables.

Confirm the driver installed:

```bash
kubectl get csidriver nfs.csi.k8s.io
kubectl get pods -n kube-system -l app=csi-nfs-controller -o wide
kubectl get pods -n kube-system -l app=csi-nfs-node -o wide
kubectl rollout status deployment/csi-nfs-controller -n kube-system --timeout=300s
kubectl rollout status daemonset/csi-nfs-node -n kube-system --timeout=300s
```

Rerun the tagged playbook to check that an unchanged installation reports
`changed=0`. Also test a workload mounting your NAS export: driver readiness
alone does not verify export permissions or access to the stored data.

#### Creating the `StorageClass` (Optional)

A `StorageClass` is needed for dynamic provisioning, where the driver creates
a subdirectory for each claim. The repository does not currently include
the previously documented `manifests/nfs-csi/` Kustomize files. If you need
dynamic provisioning, save the following as your own `storageclass.yaml`,
filling in your NAS address and export path:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-csi
provisioner: nfs.csi.k8s.io
parameters:
  server: <your-nas-ip-or-hostname>
  share: <path-to-your-nfs-export>
reclaimPolicy: Retain
volumeBindingMode: Immediate
mountOptions:
  - nfsvers=4.1
```

Then apply it:

```bash
kubectl apply -f storageclass.yaml
```

NFSv4.1 needs to be enabled on the NAS side too (on Synology DSM: Control
Panel → File Services → NFS). Allow the relevant node addresses in the
export permissions. `Retain` leaves the volume and its data for manual
cleanup after a claim is deleted.

#### Creating a PersistentVolumeClaim

There are two ways to actually consume storage, matching
`csi-driver-nfs`'s own terminology for them. PVs and PVCs belong to the
workload configuration, separate from the cluster driver installation.

**Dynamic provisioning** - let the driver create a new subdirectory under
your `share` path automatically, one per `PersistentVolumeClaim`. Create a
PVC with `storageClassName: nfs-csi` to use the `StorageClass` above; the
driver creates the PV for you.

**Static provisioning** - bind to one *specific*, already-existing folder
on your NAS instead of letting the driver create a new one. Define a PV
with `csi.driver: nfs.csi.k8s.io`, the `server`/`share` attributes, and a
unique `volumeHandle`, following the
[driver's own static provisioning example](https://github.com/kubernetes-csi/csi-driver-nfs/blob/master/deploy/example/README.md#pvpvc-usage-static-provisioning),
then bind a PVC to it with `volumeName`. Set `storageClassName: ""` on both
the PV and PVC if no StorageClass should be used. Preserve existing volume
handles, export paths, and bindings when bringing resources under management.
After applying your workload's PV/PVC definitions, check their status:

```bash
kubectl get pv
kubectl get pvc -A
```

`STATUS` should read `Bound` for both once the claim picks up the volume.

### Setting Up Synology CSI iSCSI Storage

The Ansible `synology_csi` role installs Synology CSI `v1.4.0` for a Synology
NAS with SAN Manager. It creates the `synology-csi` namespace, the DSM client
secret, the CSI controller and node plugin, and the `synology-iscsi-storage`
StorageClass. The class provisions iSCSI LUNs on `/volume1`, uses `ext4`, waits
for the first consumer, allows expansion, and keeps deleted volumes with
`Retain`. It is not made the cluster default; `local-path` remains available
for workloads that do not need shared block storage.

FCOS already provides the iSCSI initiator tools. Both Butane templates enable
`iscsi-init.service` and `iscsid.service`; no NFS package, NFS mount, or
additional host layering is needed for Synology CSI. Every node that may run a
PVC workload must have network access to the NAS's iSCSI port (3260) and DSM
HTTPS port (5001).

Create a dedicated DSM user in the administrators group, allow it to access
DSM, and put its password in the encrypted vault. Then run the role from
`ansible/`:

```bash
ansible-vault edit inventory/group_vars/all/vault.yml
# add: synology_csi_dsm_password: <the DSM CSI user's password>
ansible-playbook playbooks/bootstrap-cluster.yml --syntax-check
ansible-playbook playbooks/bootstrap-cluster.yml --tags synology_csi
```

The role pins the upstream manifests and verifies that the controller and node
DaemonSet are ready. It registers the driver with `attachRequired: false`
because Synology CSI `v1.4.0` does not implement controller-side publish and
unpublish calls. Before using this class for application data, create a small
PVC and pod and confirm the volume appears in DSM and mounts successfully:

```bash
kubectl get csidriver csi.san.synology.com
kubectl get pods -n synology-csi -o wide
kubectl get storageclass synology-iscsi-storage
```

The driver can reconnect a volume on another node after a failure, but it does
not fence a node that still has an iSCSI session. Confirm the failed node is
powered off or otherwise fenced before forcing a single-writer workload to
another node. Keep backups of application data outside the Synology volume.

---

### Deploying Emby

Emby is deployed separately from cluster bootstrap as a single-replica
**StatefulSet**. The application role creates the `emby` namespace, storage
claims, the `emby-0` pod, a headless Service, and a dedicated LoadBalancer
Service at **<emby-service-ip>**. An NGINX HTTPS proxy runs in the same pod as
Emby, using a certificate from the Let's Encrypt production issuer.

```
Client -> <emby-service-ip>:443 -> Emby worker -> NGINX -> localhost:8096 -> Emby
```

MetalLB advertises the service IP from the worker with the ready Emby pod.
`externalTrafficPolicy: Local` keeps incoming traffic on that worker. The
StatefulSet can move between workers; DNS and the client IP remain unchanged.
Rescheduling interrupts streams while storage reconnects and the pod starts.

*   **Config (`/config`)**: A `ReadWriteOnce` claim backed by the
    `synology-iscsi-storage` class stores Emby's database and configuration on
    a Synology iSCSI LUN.
*   **Media (`/media`)**: The role creates a static NFS PV and PVC using
    `nfs.csi.k8s.io`. You provide the NAS export; no pre-existing media claim
    or NFS StorageClass is needed. Media is mounted read-only by default.

After completing cluster bootstrap, enable NFSv4.1 on the Synology and allow
all eligible K3s nodes to access the media export. Reserve `<emby-service-ip>` outside DHCP and leave it unassigned to any machine.
Point LAN DNS for `emby.<your-domain>` at that address. All eligible workers
must share its layer-2 network, allow TCP 443 from clients, and allow TCP/UDP
7946 between MetalLB speakers. Use at least two workers to support movement.

MetalLB uses the explicit `metallb.io/metallb` load-balancer class. K3s
ServiceLB continues managing unclassified services such as shared Traefik;
Emby's traffic uses its dedicated service. No Butane changes are needed.
See the [MetalLB role guide](ansible/roles/metallb/README.md) for network
requirements. On an already bootstrapped cluster, install MetalLB from `ansible/`:

```bash
ansible-playbook playbooks/bootstrap-cluster.yml --tags metallb
```

From `ansible/`, edit the role's settings:

```bash
${EDITOR:-vi} roles/emby/defaults/main.yml
```

Set `emby_version` to a pinned official image tag and `emby_uid`/`emby_gid`
to numeric IDs with permission to read your media. Review the config volume
size and hostname there too. Keep these public settings in the role defaults.
Store the private media export path and service IP in encrypted Vault alongside `domain`
and `synology_csi_dsm_host`:

```bash
ansible-vault edit inventory/group_vars/all/vault.yml
```

Add or update these keys using the DSM export path and your reserved LAN IP:

```yaml
emby_media_nfs_share: "/volume1/<media-export>"
emby_service_ip: "<emby-service-ip>"
```

Leave `emby_media_nfs_share` and `emby_service_ip` empty in the role defaults;
Vault supplies their values.
The NFS server defaults to `synology_csi_dsm_host`, so both storage types use
the same NAS address.

Deploy the application:

```bash
ansible-playbook playbooks/applications/emby.yml --syntax-check
ansible-playbook playbooks/applications/emby.yml
```

The config claim can remain `Pending` until the pod is scheduled because the
Synology StorageClass uses `WaitForFirstConsumer`. The role waits for the
StatefulSet and TLS certificate to become ready. Verify the result:

```bash
kubectl get statefulset,pods,pvc,svc -n emby
kubectl get certificate -n emby
kubectl logs emby-0 -n emby -c emby
```

Open `https://emby.<your-domain>` and complete the first-run wizard. Add media
libraries using paths beneath `/media`. Keep the StatefulSet at one replica
because it uses a single config claim. Back up the config data; NAS storage
surviving a node loss does not replace backups.

See the [Emby role guide](ansible/roles/emby/README.md) for the full Ansible
and Kubernetes lesson, NAS permissions, storage checks, troubleshooting, and
maintenance commands.

---

### Deploying Headscale

Headscale is deployed separately from cluster bootstrap. Its role uses a
dedicated MetalLB address and an NGINX HTTPS sidecar, with a Let's Encrypt
production certificate, one Headscale replica and a persistent SQLite database.

The data claim uses the `synology-iscsi-storage` class, matching Emby's config
volume. The role retains the PV and can reattach it after claim deletion. Set
the reserved `headscale_service_ip` in the encrypted vault. The database and
SQLite WAL files use iSCSI block storage, not the NFS media share. Configure
public DNS and router TCP 443 forwarding to the Headscale service IP for
`headscale.compvirt.com`, using Cloudflare **DNS only**.

From `ansible/`, after completing those prerequisites:

```bash
ansible-playbook playbooks/applications/headscale.yml
```

NGINX terminates TLS in the Headscale pod and forwards to Headscale over the
pod's loopback interface. MetalLB advertises the service IP from the worker
hosting the ready pod, and `externalTrafficPolicy: Local` keeps client traffic
on that worker. After the first successful deployment, pin the PV name printed
by the role in `inventory/group_vars/all/vars.yml`; the role sets its reclaim
policy to `Retain` and can reattach it after claim deletion. See the
[Headscale role guide](ansible/roles/headscale/README.md) for storage
requirements, DNS, client registration, verification, and backup instructions.

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
