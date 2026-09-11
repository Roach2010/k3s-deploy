# FCOS + k3s Deployment on VMware (govc)

Scripts and Butane/Ignition templates for deploying a k3s Kubernetes cluster
on Fedora CoreOS (FCOS) VMs, running on VMware ESXi/vSphere, driven entirely
by `govc`.

## What's in this repo

```
.
├── fcos-k3s-controlplane.bu   Butane template for the control-plane node
├── fcos-k3s-worker.bu         Butane template for worker nodes
├── deploy-controlplane.sh     Deploys the control-plane VM (self-contained)
├── deploy-worker.sh           Deploys a worker VM (self-contained)
├── deploy.env.example         Template for your local secrets/config file
├── .gitignore                 Excludes deploy.env, rendered/, and ova/
├── rendered/                  Generated per-host .bu/.ign files (gitignored)
└── ova/                       Downloaded FCOS OVA cache (gitignored)
```

Each deploy script is fully self-contained — no shared library file to
jump to. There's duplication across the three (each has its own copy of
the datastore-selection, OVA-download, and import logic), which is a
deliberate trade-off for being able to read one script top-to-bottom
without cross-referencing another file.

Only `deploy.env` (your real secrets), `rendered/` (generated output), and
`ova/` (downloaded binary) are excluded from version control — everything
else here is safe to commit.

## How it works

1. You run `deploy-controlplane.sh` or `deploy-worker.sh` with a hostname.
2. The script resolves the FCOS OVA to use: if `FCOS_OVA` is unset in
   `deploy.env`, it fetches the latest OVA for `FCOS_STREAM` (default
   `stable`) from Fedora CoreOS's build metadata, verifies its sha256, and
   caches it in `./ova/` (skipping re-download if already current). If
   `FCOS_OVA` is set to a local path instead, that pinned file is used as-is.
3. The script renders the matching `.bu` Butane template with real values
   substituted in from `deploy.env`, then compiles it to Ignition JSON with
   `butane`.
4. `govc` imports the OVA into vSphere, places it on a datastore
   selected automatically from a datastore cluster, maps its NIC to your
   portgroup, and injects the Ignition config via `guestinfo`.
5. The VM's MAC address is printed so you can add a DHCP reservation before
   or after first boot.
6. On first boot, Ignition writes SSH keys, hostname, and a one-shot systemd
   unit that installs k3s (server or agent) and layers `open-vm-tools`
   (absent from the base FCOS image). Once everything succeeds, the VM
   reboots itself once to finalize the `open-vm-tools` layer.

## Prerequisites

- `govc` (VMware CLI), authenticated against your vCenter
- `butane` (or the `quay.io/coreos/butane` container image)
- `jq`
- `curl` (used to fetch FCOS stream metadata and download the OVA, unless
  you pin a local one via `FCOS_OVA`)
- A vSphere datastore **cluster** (Storage DRS) — see note below if you use
  a single datastore instead
- An SSH keypair; you supply the public key, k3s uses a shared token you
  choose yourself (no need to fetch a generated token off the control-plane)

## Setup

```bash
cp deploy.env.example deploy.env
```

Edit `deploy.env` and fill in every value — see [Configuration
reference](#configuration-reference) below. `.gitignore` is already set up
to exclude `deploy.env`, `rendered/`, and `ova/`.

Make the scripts executable if they aren't already:

```bash
chmod +x deploy-controlplane.sh deploy-worker.sh
```

## Usage

Deploy the control-plane first — workers need it reachable to join:

```bash
./deploy-controlplane.sh k3s-cp1
```

Deploy one or more workers, giving each a unique hostname:

```bash
./deploy-worker.sh k3s-worker1
./deploy-worker.sh k3s-worker2
```

### Waiting for a DHCP reservation

The VM's MAC address is assigned when it's imported, before it's ever
powered on. If you want to reserve `CONTROL_PLANE_IP` for the control-plane
in your DHCP server *before* first boot (rather than relying on a second
boot to pick it up), pass `--wait-for-reservation` (or `-w`):

```bash
./deploy-controlplane.sh k3s-cp1 --wait-for-reservation
```

The script prints the MAC address and pauses so you can add the reservation,
then continues once you press Enter.

Both scripts accept multiple flags together and in any order, e.g.
`./deploy-controlplane.sh k3s-cp1 -w -c`.

### High availability: `--cluster-init` and `--join`

By default the control-plane uses k3s's built-in SQLite datastore, which
is fine for a single control-plane node. For HA (multiple control-plane
nodes), switch to the embedded etcd datastore:

```bash
# First control-plane node only - creates the HA cluster
./deploy-controlplane.sh k3s-cp1 --cluster-init

# Every additional control-plane node - joins the existing cluster
./deploy-controlplane.sh k3s-cp2 --join
./deploy-controlplane.sh k3s-cp3 --join
```

`--join` connects to `CONTROL_PLANE_IP` (the first node) via
`--server https://<CONTROL_PLANE_IP>:6443`. `--cluster-init` and `--join`
are mutually exclusive — the script errors if both are passed. Both flags
are control-plane only; `deploy-worker.sh` rejects them.

**The datastore choice is permanent, made once at cluster creation.**
There's no live conversion from SQLite to etcd. If you already have a
single-node SQLite cluster and want to switch to HA, you have to start
over: redeploy the control-plane fresh with `--cluster-init`, and redeploy
every worker too (a worker from the old cluster won't rejoin cleanly — the
new cluster has a different CA/certs even if you reuse the same
`K3S_TOKEN`). Deploying fresh VMs from Ignition rather than mutating
existing ones is how this toolkit works everywhere else, so this isn't a
special case.

**`--cluster-init`/`--join` alone do not make the cluster's *endpoint*
highly available**, only the etcd data. `CONTROL_PLANE_IP` is still a
single node's address — if that specific node goes down, workers and
`kubectl` lose access even though the other control-plane nodes and etcd
data are fine. Genuine endpoint HA needs something in front of all
control-plane nodes' IPs, e.g. `kube-vip` (a floating VIP among the
control-plane nodes) or an external load balancer, with `CONTROL_PLANE_IP`
and worker `K3S_URL`s pointing at that instead of any one node. Setting
that up isn't automated by this toolkit.

`EXTRA_TLS_SAN` accepts a comma-separated list if you want more than one
extra entry on the certificate, e.g. `EXTRA_TLS_SAN='k3s.roach.lan,k3s-cp2.roach.lan'`.

### What you'll see

Each script prints numbered progress steps as it works through resolving
the FCOS OVA, loading config, rendering Ignition, selecting a datastore,
importing the OVA, resolving the MAC address, and powering on — e.g.:

```
==> [1/9] Loading configuration from deploy.env
==> [2/9] Validating required variables
==> [3/9] Resolving latest Fedora CoreOS OVA (stream: stable)
==> [4/9] Rendering Butane template and compiling to Ignition
==> [5/9] Selecting a datastore from cluster 'sata_datastores'
==> [6/9] Building import spec (thin-provisioned disks, network mapped to 'VM Network')
==> [7/9] Importing OVA as 'k3s-cp1' (this may take a few minutes)
==> [8/9] Resolving VM MAC address for DHCP reservation
==> [9/9] Injecting Ignition config and powering on
```

### After deployment

Once the control-plane finishes bootstrapping and reboots, a ready-to-use
kubeconfig is already waiting at `/home/core/.kube/config`, owned by
`core` (no `sudo` needed) and pointed at `https://<KUBE_API_HOSTNAME>:6443`:

```bash
ssh core@<CONTROL_PLANE_IP>
kubectl get nodes
```

This works out of the box **only if `KUBE_API_HOSTNAME` actually resolves**
to `CONTROL_PLANE_IP` — via your own DNS server or an `/etc/hosts` entry.
Nothing in this toolkit sets that up.

Pull it to your workstation the same way, no manual editing required:

```bash
scp core@<CONTROL_PLANE_IP>:.kube/config ./kubeconfig
export KUBECONFIG=./kubeconfig
kubectl get nodes
```

The system-level file at `/etc/rancher/k3s/k3s.yaml` still always shows
`server: https://127.0.0.1:6443` — that one's k3s's own admin config, gets
regenerated on every service start, and is deliberately left untouched;
see the design note below on why. `/home/core/.kube/config` is a separate,
one-time copy that k3s never touches again, which is what makes patching
it safe.

Each node's hostname is set to `<vm-name>.<DOMAIN_SUFFIX>` (from
`deploy.env`), e.g. deploying `k3s-cp1` with `DOMAIN_SUFFIX=cluster.local`
gives it the hostname `k3s-cp1.cluster.local`.

## Configuration reference

All variables live in `deploy.env` (copy from `deploy.env.example`).

| Variable | Description |
|---|---|
| `GOVC_URL` | vCenter hostname/FQDN |
| `GOVC_USERNAME` | vCenter username |
| `GOVC_PASSWORD` | vCenter password |
| `GOVC_INSECURE` | `true` to skip TLS cert validation |
| `DS_CLUSTER` | Name of the datastore cluster (StoragePod) to deploy into |
| `NETWORK` | Portgroup name to attach the VM's NIC to |
| `FCOS_STREAM` | Fedora CoreOS release stream to auto-download the latest OVA from (`stable`, `testing`, or `next`). Ignored if `FCOS_OVA` is set. |
| `FCOS_OVA` | Optional. Leave blank to auto-download the latest OVA for `FCOS_STREAM` into `./ova`. Set to a local file path to pin a specific OVA instead. |
| `VM_FOLDER` | Full vCenter inventory path of the VM folder to import into, e.g. `/Datacenter/vm/k3s` |
| `DOMAIN_SUFFIX` | Domain suffix appended to each VM's hostname |
| `SSH_PUBLIC_KEY_1` | Your SSH public key, added to the `core` user |
| `K3S_TOKEN` | Shared secret used for both server and agent join — pick your own value |
| `CONTROL_PLANE_IP` | Control-plane's intended IP (used in k3s's TLS SAN and for workers to join) |
| `KUBE_API_HOSTNAME` | Hostname for the core user's kubeconfig `server:` line; auto-added to TLS SAN |
| `EXTRA_TLS_SAN` | Optional. Comma-separated extra TLS SAN entries beyond `CONTROL_PLANE_IP`, e.g. a FQDN |
| `K3S_VERSION` | k3s release tag, e.g. `v1.30.4+k3s1` |
| `CLUSTER_CIDR` | Pod network CIDR (control-plane only) |
| `SERVICE_CIDR` | Service network CIDR (control-plane only) |

## Design notes / gotchas

A few non-obvious things this toolkit works around, documented here so
they don't get "fixed" back into bugs later:

- **Bootstrap logging is routed to the VM console**, not just the journal.
  The `k3s-server-install.service` / `k3s-agent-install.service` units set
  `StandardOutput=journal+console` and `StandardError=journal+console`, and
  the install scripts print `==> [k3s-bootstrap] ...` checkpoints at each
  phase (open-vm-tools, k3s install, service wait, completion, reboot).
  Deliberately not using `set -x` for this — full shell tracing would print
  the `curl` command containing `K3S_TOKEN` in plaintext to the console,
  visible to anyone with vCenter console access.
- **The k3s service is explicitly enabled and started**
  (`systemctl enable --now k3s` / `k3s-agent`) rather than relying on the
  `get.k3s.io` installer to have done so — in testing, the installer
  completing successfully didn't guarantee the service was actually
  started, which left the wait loop timing out with nothing obviously
  wrong in the install step itself.
- **Bootstrap fails loudly, on purpose, if k3s doesn't come up.** If the
  wait loop times out, the script prints the last 50 journal lines for
  `k3s`/`k3s-agent` and exits without marking bootstrap complete or
  rebooting — so a real failure leaves the VM up for live debugging
  instead of silently rebooting into the same broken state.
- **`/etc/rancher/k3s/k3s.yaml` always shows `server: https://127.0.0.1:6443`
  — leave it alone, don't patch it in place.** k3s regenerates this file
  (it's tied to the local admin certificate) every time the service
  starts, so an in-place patch gets silently reverted on the next restart
  or reboot. Instead, the bootstrap script makes a **one-time copy** to
  `/home/core/.kube/config` with `server:` rewritten to
  `KUBE_API_HOSTNAME` — that copy is never touched by k3s again, which is
  what makes patching it safe. This applies to any additional `--join`ed
  control-plane node too; each gets its own copy pointed at the same
  `KUBE_API_HOSTNAME`.
- **`KUBE_API_HOSTNAME` is automatically folded into the TLS SAN list**,
  alongside `CONTROL_PLANE_IP` and any `EXTRA_TLS_SAN` entries. Without
  this, `kubectl` using the generated `/home/core/.kube/config` would fail
  TLS certificate validation — the hostname in `server:` has to be present
  on the cert regardless of network path, and nothing else in this toolkit
  would otherwise put it there.
- **The control-plane doesn't pin `--node-ip`/`--advertise-address`.** As
  a separate precaution, since IP assignment here is DHCP-reservation-based
  rather than static, the VM's actual address on a given boot might not
  yet match `CONTROL_PLANE_IP` (e.g. before a reservation has taken
  effect), and pinning those flags to an address the host doesn't actually
  hold would make k3s fail to bind. Only `--tls-san=CONTROL_PLANE_IP` is
  set, so the certificate stays valid for that address once DHCP actually
  assigns it; k3s auto-detects the bind address itself.
- **The FCOS OVA is resolved dynamically**, not hardcoded to a filename
  that goes stale. Each script reads Fedora CoreOS's published stream
  metadata (`https://builds.coreos.fedoraproject.org/streams/<stream>.json`),
  extracts the current OVA URL and sha256 for `x86_64`, and downloads only
  if the cached copy in `./ova/` is missing or its checksum doesn't match.
  Set `FCOS_OVA` in `deploy.env` to a local file path if you need to pin a
  specific, reproducible version instead of always deploying the latest.
- **Networking is DHCP-based**, not static. `CONTROL_PLANE_IP` is the
  address k3s puts in its TLS certificate SAN and that workers use to join —
  getting the VM's actual interface to have that address is up to your DHCP
  server (via a MAC reservation), not Ignition/NetworkManager.
- **Butane placeholders are sentinel-wrapped** (`__LIKE_THIS__`) rather than
  bare (`LIKE_THIS`). A bare placeholder can collide with substrings of real
  variable names during `sed` substitution — e.g. a bare `K3S_VERSION`
  placeholder matches inside `INSTALL_K3S_VERSION`, corrupting it.
- **`--cluster-init`/`--join` resolve to a plain string**, substituted
  into the Butane template the same way every other value is:
  `deploy-controlplane.sh` computes `CP_EXTRA_FLAG` as one of
  `--cluster-init`, `--server https://<CONTROL_PLANE_IP>:6443`, or an
  empty string, based on which flag was passed — the Butane template
  itself never branches on mode. `deploy-worker.sh` parses (and rejects)
  `--cluster-init`/`--join` too, since there's no shared arg-parsing code
  to reuse.
- **TLS SAN accepts multiple values via a comma-separated `deploy.env`
  variable.** k3s supports repeating `--tls-san` per value, so each script
  splits a comma-separated string (trimming whitespace around each entry)
  into the repeated flags — one variable in `deploy.env` can hold e.g.
  both an IP and a FQDN. Used for `EXTRA_TLS_SAN`, additive to
  `CONTROL_PLANE_IP`.
- **Disks are thin-provisioned.** Each script sets
  `DiskProvisioning: "thin"` in the same `-options` spec used for network
  mapping — `govc import.ova` has no standalone flag for this either,
  same as networking.
- **`govc import.ova` has no `-network` flag.** Network mapping only works
  via an `-options` JSON spec with a `NetworkMapping` array (built from
  `govc import.spec` and edited with `jq`); the scripts do this
  automatically.
- **Datastore cluster members aren't listed by `govc find -parent`.**
  `govc ls <StoragePod path>` is the reliable way to enumerate them; this
  is what each script's datastore-selection step uses.
- **`open-vm-tools` isn't on the base FCOS image.** It's layered via
  `rpm-ostree install` during bootstrap and only takes effect after a
  reboot — which is why the bootstrap script ends with `systemctl reboot`,
  reached only if every prior step succeeded (`set -euo pipefail`).
- **The k3s token is a plain shared secret**, not the auto-generated
  `K10<hash>::server:<secret>` token k3s would otherwise write to
  `/var/lib/rancher/k3s/server/node-token`. This skips a manual
  fetch-token-then-configure-agent step, at the cost of TLS
  trust-on-first-use instead of hash-verified join. Fine for a trusted
  private subnet; reconsider if that's not your environment.
- **The token is delivered as a file, not a CLI argument.** Ignition
  writes it to `/etc/rancher/k3s/token` (`root:root`, mode `0600`), and
  both `k3s server` and `k3s agent` are started with
  `--token-file=/etc/rancher/k3s/token` instead of `--token=<value>`.
  A token passed via `--token` sits in the running process's command
  line for as long as the service runs, visible to anyone with shell
  access via `ps aux`; a restrictive file avoids that exposure.

## Troubleshooting

- **`kubectl` fails to connect using `/home/core/.kube/config`** — check
  that `KUBE_API_HOSTNAME` actually resolves to `CONTROL_PLANE_IP` from
  wherever you're running `kubectl` (`getent hosts <hostname>` or
  `nslookup`). This toolkit only puts the hostname in the kubeconfig and
  the certificate's SAN list; DNS/`/etc/hosts` resolution is on you.
- **"Could not resolve a datastore from cluster ..."** — confirm
  `govc ls <StoragePod path>` (resolved via `govc find / -type StoragePod
  -name "${DS_CLUSTER}"`) actually returns datastore paths.
- **"Checksum mismatch after download!"** — the OVA download was
  interrupted or corrupted; re-run the script (it retries automatically
  since the partial file is never kept as the final `.ova`). If it persists,
  check connectivity to `builds.coreos.fedoraproject.org`.
- **Control-plane IP not what you expect after boot** — check that DHCP
  actually reserved `CONTROL_PLANE_IP` for the printed MAC address; nothing
  in Ignition configures a static IP.
- **Kubeconfig on the VM shows `127.0.0.1` instead of `CONTROL_PLANE_IP`**
  — this is expected, not a bug; k3s regenerates that file on every service
  start. See [After deployment](#after-deployment) for pulling a working
  copy locally instead of expecting the VM's own file to be pre-patched.
- **"k3s did not become active" / the VM never reboots after deploy** — the
  bootstrap script exits (without rebooting) and prints the last 50
  journal lines for `k3s`/`k3s-agent` on the console when this happens.
  Current templates explicitly run `systemctl enable --now k3s` (or
  `k3s-agent`) after install rather than assuming the installer started it,
  which was the cause of this in testing. If you still hit it, check the
  printed journal output for the actual failure and re-run the unit with
  `systemctl restart k3s-server-install.service` (or
  `k3s-agent-install.service` on a worker) once resolved.
- **`jq` not found** — required for datastore selection and import-spec
  building; install via your package manager (`dnf install jq` /
  `apt install jq`).
- **Not seeing bootstrap output on the console** — open the VM's console
  in vCenter before or immediately after power-on; bootstrap runs early in
  boot and finishes with an automatic reboot, so opening the console late
  can mean missing most or all of the log output.
