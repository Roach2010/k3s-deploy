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
├── deploy.env.example         # Template for cluster configuration and credentials
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
| `CONTROL_PLANE_IP` | The IP address that your primary control plane node will obtain via DHCP. |
| `KUBE_API_HOSTNAME` | The DNS hostname pointing to your control plane (added to API TLS certs). |
| `EXTRA_TLS_SAN` | *(Optional)* Extra IPs or hostnames to include in the API server TLS certificate. |
| `K3S_VERSION` | Exact release tag of k3s (e.g., `v1.30.4+k3s1`). |
| `CLUSTER_CIDR` | Internal IP space reserved for Pods (e.g., `10.42.0.0/16`). |
| `SERVICE_CIDR` | Internal IP space reserved for Services (e.g., `10.43.0.0/16`). |

Make the deployment scripts executable:

```bash
chmod +x deploy-controlplane.sh deploy-worker.sh
```

---

## 5. Deploying the Cluster

### Step 1: Deploy the First Control Plane Node

Run the control plane deploy script with your desired VM host name:

```bash
./deploy-controlplane.sh k3s-cp1
```

#### Handling DHCP Reservations (`--wait-for-reservation`)
If you want to pin `CONTROL_PLANE_IP` in your DHCP server before the node boots for the first time, use the `-w` or `--wait-for-reservation` flag:

```bash
./deploy-controlplane.sh k3s-cp1 --wait-for-reservation
```

The script will configure the vSphere VM, print its generated **MAC Address**, and pause. You can then add the MAC-to-IP reservation in your router or DHCP server before pressing **Enter** to power on the VM.

### Step 2: (Optional) High Availability Control Plane setup

By default, k3s uses an embedded SQLite database suitable for single control-plane setups. If you want a High Availability (HA) control plane with multiple API nodes, k3s uses an embedded **Etcd** cluster.

1.  **Initialize the HA cluster on node 1**:
    ```bash
    ./deploy-controlplane.sh k3s-cp1 --cluster-init
    ```
2.  **Join additional control plane nodes**:
    ```bash
    ./deploy-controlplane.sh k3s-cp2 --join
    ./deploy-controlplane.sh k3s-cp3 --join
    ```

> **Linux Note on High Availability**: High Availability mode controls how the cluster stores state internally via Etcd. To make the Kubernetes API endpoint highly available to external clients, you must place an external Load Balancer or virtual IP mechanism (like `kube-vip`) in front of your control plane nodes, and point `CONTROL_PLANE_IP` and `KUBE_API_HOSTNAME` to that endpoint.

### Step 3: Deploy Worker Nodes

Worker nodes run workloads and report back to the control plane. Pass a unique hostname for each worker:

```bash
./deploy-worker.sh k3s-worker1
./deploy-worker.sh k3s-worker2
```

---

## 6. Accessing and Operating the Cluster

When a host boots for the first time, Ignition executes the following sequence:
1. Formats disk partitions, writes SSH keys, and generates system config.
2. Runs a systemd setup unit that installs `k3s`.
3. Runs `rpm-ostree install open-vm-tools` to add VMware drivers to the base FCOS image.
4. Generates a user-accessible `kubeconfig` file at `/home/core/.kube/config`.
5. Initiates an automated system reboot to finalize the `rpm-ostree` driver layer.

### Connecting to the Cluster with `kubectl`

Once the primary control plane node finishes its final reboot, log into the machine via SSH:

```bash
ssh core@<CONTROL_PLANE_IP>
```

You can execute `kubectl` commands immediately on the machine:

```bash
kubectl get nodes
```

To manage the cluster from your local workstation, copy the generated `kubeconfig` file off the host:

```bash
# Copy the config to your local machine
scp core@<CONTROL_PLANE_IP>:.kube/config ./kubeconfig

# Point your local environment to the file
export KUBECONFIG=$(pwd)/kubeconfig

# Test connection
kubectl get nodes -o wide
```

> **Why check `/home/core/.kube/config` instead of `/etc/rancher/k3s/k3s.yaml`?**
> The system file at `/etc/rancher/k3s/k3s.yaml` is k3s's internal admin configuration. k3s automatically overwrites this file on every service restart to point to `127.0.0.1:6443`. To protect user settings, our deployment script creates a separate one-time copy in `/home/core/.kube/config` mapped to `KUBE_API_HOSTNAME`.

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

*   **`kubectl` cannot connect to `KUBE_API_HOSTNAME`**: Verify that your local computer can resolve `KUBE_API_HOSTNAME` to `CONTROL_PLANE_IP` via your local `/etc/hosts` or DNS server.
*   **Token security**: The cluster token is saved on the node under `/etc/rancher/k3s/token` with restricted permissions (`0600`). This prevents sensitive tokens from leaking into process listings (`ps aux`).
*   **FCOS Updates & Layering**: Fedora CoreOS updates automatically over time. Custom additions like `open-vm-tools` are layered on top of the underlying OS image via `rpm-ostree`. You can view current OS tree status using:
    ```bash
    rpm-ostree status
    ```
