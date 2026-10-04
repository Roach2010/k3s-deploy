# How to Deploy Emby with Ansible, Synology iSCSI and NFS

This guide builds a fresh Emby installation on K3s. It assumes you know Linux
and explains the Ansible and Kubernetes concepts alongside the commands.

The role creates a single-replica StatefulSet named `emby`, a Synology iSCSI
config claim, an NFS media PV and PVC, two Services, a Certificate, and an
NGINX HTTPS proxy in the same pod. You provide a NAS media export, a pinned image tag and numeric
user/group IDs with permission to read that export.

Run commands on your Linux management machine unless a step explicitly says
to SSH into a K3s node. Examples use namespace `emby`. Replace angle-bracket
placeholders with your settings.

## 1. Understand the Architecture

Butane/Ignition provisions FCOS and the node services. K3s runs the Kubernetes
API and node agents. The Ansible cluster bootstrap installs shared services:
CSI drivers, cert-manager, the Cloudflare secret, and certificate issuers.
The Emby application playbook then calls this role.

Ansible runs on the management machine and talks to the Kubernetes API using
your kubeconfig. It does not SSH into each node to install Emby. Once Ansible
exits, Kubernetes continues maintaining the requested application state.

```text
Ansible management machine
    |
    v
K3s API -> StatefulSet -> Emby Pod (emby-0)
                                       | /config -> PVC -> PV -> Synology LUN
                                       | media   -> role-managed PVC/PV -> NFS export

Browser -> <emby-service-ip>:443 -> Emby worker -> NGINX -> localhost:8096
```

| Object | Meaning in this deployment |
| :--- | :--- |
| Namespace | The scope containing Emby's workload and storage claims. |
| StatefulSet | Maintains the stable pod identity `emby-0` and replaces it during updates. |
| Headless Service | `emby-headless` provides the StatefulSet's governing network identity. |
| Pod | A replaceable container instance scheduled onto one node. |
| PVC | A namespaced storage request referenced by a pod. |
| PV | The cluster-wide storage object bound to a claim. |
| StorageClass | Provisioning settings selecting a storage driver and backend. |
| CSI driver | Provisions storage and connects it to the node running the pod. |
| Service | A stable internal address selecting ready pods by label. |
| LoadBalancer Service | MetalLB advertises a stable LAN IP from the worker hosting Emby. |
| HTTPS proxy | NGINX shares Emby's pod and forwards to localhost, avoiding an extra node hop. |
| Certificate | A cert-manager resource managing the proxy TLS certificate. |

The config volume uses the `synology-iscsi-storage` class. The node mounts the
block device as a filesystem; Emby sees normal files at `/config`. Media uses
the NFS claim mounted at `/media` by default.

`ReadWriteOnce` allows writable mounting on one node, not necessarily one pod.
This role uses a single StatefulSet replica and `RollingUpdate`: Kubernetes
terminates `emby-0` before creating its replacement during a normal update.
Do not increase replicas: every replica would reference the same config PVC.
The claim is deliberately separate rather than a `volumeClaimTemplates`
entry, so its lifecycle is independent of the StatefulSet. Storage on the NAS survives a K3s node loss, but a single NAS
is still a failure domain. See
[Kubernetes persistent volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/).

## 2. Learn the Ansible Layout

These paths are relative to the repository's `ansible/` directory:

```text
ansible.cfg                              # Inventory, role and Vault settings
inventory/hosts.yml                      # The local management host
inventory/group_vars/all/vars.yml        # Shared Ansible settings
inventory/group_vars/all/vault.yml       # Encrypted private settings
playbooks/bootstrap-cluster.yml          # Shared cluster services
playbooks/applications/emby.yml          # Calls this role
roles/emby/defaults/main.yml             # Overridable settings
roles/emby/tasks/main.yml                # Ordered tasks and validation
roles/emby/templates/resources.yml.j2     # Kubernetes resources
```

The application playbook is small:

```yaml
---
- name: Deploy Emby
  hosts: localhost
  connection: local
  gather_facts: false

  roles:
    - emby
```

Ansible automatically loads the role's tasks and defaults. Inventory variables
override role defaults; command-line extra variables (`-e`) override inventory.
Avoid defining the same variable in multiple inventory files. Store private
settings, including `emby_media_nfs_share` and `emby_service_ip`, in encrypted Vault. Keep public
Emby settings and its version pin in
`roles/emby/defaults/main.yml`.

A role groups related tasks, templates and defaults. Jinja expressions such
as `{{ emby_version }}` substitute variables into the manifests. In this role,
`state: present` requests that a resource exist, `apply: true` reconciles its
configuration, `register` captures a result, and `assert` checks a prerequisite.
Tags select a subset of tasks, such as storage preparation.

See [Ansible roles](https://docs.ansible.com/projects/ansible/latest/playbook_guide/playbooks_reuse_roles.html)
for the standard directory structure.

## 3. Check Tools and Cluster Access

Start in the repository's `ansible/` directory and activate your existing
Ansible Python environment. Commands below install the repository's collection
requirements and Kubernetes client dependencies into that environment.

```bash
cd /path/to/k3s-deploy/ansible
ansible --version
ansible-galaxy collection install -r requirements.yml
python -m pip install kubernetes PyYAML jsonpatch
kubectl config current-context
kubectl get nodes -o wide
```

Confirm the context is the cluster you intend to change and the intended
nodes are Ready. Server nodes can also run applications unless taints or other
scheduling rules prevent it. This role does not configure GPU access.

Both tools must use the same cluster credentials. `kubectl` uses `KUBECONFIG`
or its default `~/.kube/config`; the role explicitly reads the Ansible
`kubeconfig` variable. Exporting `KUBECONFIG` does not override that variable.
Keep it defined once in your existing inventory, for example in Vault:

```yaml
kubeconfig: "{{ lookup('env', 'HOME') }}/.kube/config"
```

On a K3s server, `sudo k3s kubectl get nodes` uses that server's administrative
configuration. Use your management kubeconfig for this walkthrough. If remote
access is not yet configured, follow the repository's access instructions and
[K3s cluster access](https://docs.k3s.io/cluster-access). Never commit the
administrative kubeconfig to Git.

## 4. Verify the Shared Infrastructure

```bash
kubectl get csidriver
kubectl get pods -n synology-csi -o wide
kubectl get pods -n kube-system -l app=csi-nfs-node -o wide
kubectl get storageclass synology-iscsi-storage -o yaml
kubectl get clusterissuer letsencrypt-production
kubectl get pods -n metallb-system -o wide
```

You need Synology CSI, a working NFS path for media, the Synology StorageClass,
MetalLB, and a Ready production issuer. If infrastructure has not been
installed, use the existing bootstrap:

```bash
ansible-playbook playbooks/bootstrap-cluster.yml
```

Bootstrap is separate from application deployment. Do not rerun it merely to
diagnose a mount failure. DSM credentials and certificate trust are configured
in the Synology role, not in the Emby role.

All eligible nodes need DSM HTTPS access (normally TCP 5001) and iSCSI access
(TCP 3260), including through inter-VLAN and DSM firewalls. NFS export access
must work from those nodes too. To inspect host iSCSI setup, SSH into a node:

```bash
command -v iscsiadm
sudo systemctl status iscsid.service --no-pager
sudo cat /etc/iscsi/initiatorname.iscsi
```

Every node needs a unique initiator identity; do not copy an IQN between nodes.
Host service setup belongs to node provisioning.

## 5. Configure the Role

In `roles/emby/defaults/main.yml`, set a pinned official image tag:

```yaml
emby_version: "<pinned-image-tag>"
```

Edit the remaining public Emby settings in the same defaults file:

```bash
${EDITOR:-vi} roles/emby/defaults/main.yml
```

Ansible automatically loads this file when the Emby role runs. Shared private
settings such as DSM credentials remain in Vault.

Update the existing settings below rather than adding duplicate YAML keys:

```yaml
emby_media_mount_path: "/media"
emby_uid: "<numeric-uid>"
emby_gid: "<numeric-gid>"
emby_config_storage_size: 10Gi
# Optional:
# emby_gidlist: "1000,1001"
# emby_media_read_only: false
```

Store the private NFS export path and reserved service IP in Vault:

```bash
ansible-vault edit inventory/group_vars/all/vault.yml
```

Add or update these keys in the decrypted editor, then save and close it:

```yaml
emby_media_nfs_share: "/volume1/<media-export>"
emby_service_ip: "<emby-service-ip>"
```

Use the actual export path shown by DSM and the reserved service IP. Vault
overrides the empty fallbacks in the role defaults; leave those fallbacks empty.

Angle-bracket values are placeholders. The official image uses the UID, GID
and GIDLIST environment variables supplied by the template. Media is read-only
by default; enable writing only if Emby should modify media or save metadata
beside it.

| Variable | Default or requirement |
| :--- | :--- |
| `emby_version` | Required pinned tag; no automatic latest version. |
| `emby_image` | `emby/embyserver`. |
| `emby_namespace` | `emby`; both claims must exist in this namespace. |
| `emby_hostname` | `emby.{{ domain }}`, with `domain` supplied by inventory. |
| `emby_config_claim` | Claim `emby-config-iscsi`. |
| `emby_config_storage_class` | `synology-iscsi-storage`. |
| `emby_config_storage_size` | `10Gi`; allow space for metadata and future growth. |
| `emby_media_manage` | `true`; create the static NFS PV and PVC. |
| `emby_media_nfs_server` | Defaults to `synology_csi_dsm_host` from inventory; no separate NAS address is needed. |
| `emby_media_nfs_share` | Required exported media directory; set in encrypted Vault. |
| `emby_media_pv` | `{{ emby_namespace }}-media-nfs`; unique cluster-wide PV name and CSI handle. |
| `emby_media_capacity` | `1Ti`; binding metadata, not an NFS quota. |
| `emby_media_mount_options` | `[nfsvers=4.1]`; must match NAS support. |
| `emby_media_claim` | `emby-media`; created by default, or reused with `emby_media_manage: false`. |
| `emby_media_mount_path` | `/media`; select this path when adding libraries. |
| `emby_media_read_only` | `true`. |
| `emby_uid`, `emby_gid` | Required numeric IDs with read access to the NAS media files. |
| `emby_gidlist` | Defaults to `emby_gid`. |
| `emby_service_ip` | Required reserved LAN IPv4 address; set in encrypted Vault. |
| `emby_load_balancer_class` | `metallb.io/metallb`; must match MetalLB's configured class. |
| `emby_metallb_namespace` | `metallb-system`. |
| `emby_proxy_image`, `emby_proxy_version` | Pinned NGINX image configured in role defaults. |
| `emby_cluster_issuer` | `letsencrypt-production`. |
| `emby_wait_timeout` | `300` seconds for each final readiness wait. |

Review the tasks and syntax:

```bash
ansible-playbook playbooks/applications/emby.yml --syntax-check
ansible-playbook playbooks/applications/emby.yml --list-tasks
ansible-playbook playbooks/applications/emby.yml --list-tags
```

Syntax checking cannot prove credentials, image availability, storage or data
integrity. Check mode (`--check`) still performs API reads and assertions and
cannot fully simulate resources that do not yet exist. Avoid `--diff` for
secret-bearing tasks unless you have reviewed their output handling.


## 6. Prepare the NAS Media Export

In DSM, enable NFS and create or select the shared folder containing your
media. Add NFS permissions allowing the K3s node addresses to access it.
Enable NFSv4.1 to match the role's default mount option and use the exact
export path shown by DSM as `emby_media_nfs_share`.

Allow NFSv4.1 traffic, normally TCP 2049, through the NAS and inter-VLAN
firewalls. The UID/GID you configure for Emby must have permission to traverse
directories and read files. Do not make the files world-writable to bypass a
permission error. Media is mounted read-only by default.

The role uses a static NFS volume: it mounts the export directly, so Emby
sees the media already stored there. It does not create an empty per-claim
subdirectory or copy files. The role does not configure DSM exports.

Both the PV and PVC use `storageClassName: ""` and explicit binding. This
prevents the default `local-path` class from provisioning media storage.
The PV reserves itself for the named claim using `claimRef`; the claim
references the PV using `volumeName`.

`emby_media_capacity` is Kubernetes binding metadata, not an enforced quota
or preallocation on your NAS. The PV uses `Retain`, so claim deletion does
not request deletion of the media. Do not repoint a bound PV by editing its
server, share or CSI volume handle.

### Configure the Dedicated LAN Address

Reserve `<emby-service-ip>` outside the DHCP pool. Do not assign it to a VM's
network interface. Set your LAN DNS record for the Emby hostname to this IP.
Use at least two workers on the same layer-2 network as this address if you
want Emby to move between workers. Each needs access to both NAS storage
protocols. The pod's required node affinity excludes control-plane nodes and
nodes excluded from external load balancing, without pinning a hostname.

Bootstrap installs MetalLB with `loadBalancerClass: metallb.io/metallb`.
Emby's Service explicitly selects that class, while K3s ServiceLB handles
unclassified services. Leave K3s ServiceLB and shared Traefik enabled.
The application creates a single-address pool with automatic allocation
disabled and restricted to its labelled service in the Emby namespace.
The pool and its advertisement live in `metallb-system`.

Allow TCP 443 from clients to the service IP and TCP/UDP 7946 between speaker
nodes. The network must permit ARP advertisements. If kube-proxy has been
changed to IPVS mode, enable strict ARP as described in the
[MetalLB installation guide](https://metallb.io/installation/).

MetalLB's [local traffic policy](https://metallb.io/usage/) announces this
address from the node with a ready service endpoint. NGINX and Emby are in
one pod, so HTTPS termination and playback use the same worker. The proxy
supports WebSockets and streaming without response buffering. Cert-manager
uses DNS-01, so issuance does not depend on this service being reachable.
The proxy checks mounted certificate files every ten seconds and reloads
NGINX after renewal; Kubernetes Secret projection can add a delay.

For access from outside your LAN, separately configure public DNS and router
TCP 443 forwarding to this IP. A router forwarding TCP 443 to shared Traefik
cannot simultaneously forward that same public IP and port to Emby. This
role does not change public DNS or router rules.

## 7. Deploy the Application

Once cluster infrastructure and your variables are ready, run:

```bash
ansible-playbook playbooks/applications/emby.yml --syntax-check
ansible-playbook playbooks/applications/emby.yml
```

The role validates the storage drivers, creates the namespace and claims,
waits for the media claim to bind, and creates the MetalLB pool and Certificate.
It waits for a Ready certificate before starting the StatefulSet and HTTPS
proxy, then waits for the current pod revision and service IP allocation.

The config claim uses Synology's `WaitForFirstConsumer` binding mode, so it
may remain Pending until `emby-0` is scheduled. This is expected: the role
does not wait for config binding before creating its consumer. The media
claim binds directly to its static NFS PV.

To prepare only storage, use:

```bash
ansible-playbook playbooks/applications/emby.yml --tags emby_storage
kubectl get pvc -n emby
```

This creates storage resources without starting Emby. Run the full playbook
afterwards to create the application. The config claim can remain Pending
between these commands.

A failed assertion stops the run. Read its message before changing settings.
A failure later in the playbook does not undo tasks that already succeeded.
Ansible's `ok` means no required change was reported; `changed` means a
modification was reported. Repeating an unchanged run should normally settle
at `changed=0`. This is idempotency, not a substitute for checking playback.

## 8. Verify Each Layer

```bash
kubectl get pod,pvc,svc -n emby
kubectl rollout status statefulset/emby -n emby --timeout=300s
kubectl logs statefulset/emby -n emby -c emby --tail=100
kubectl logs statefulset/emby -n emby -c https-proxy --tail=100
kubectl get certificate emby-tls -n emby
kubectl get endpointslice -n emby -l kubernetes.io/service-name=emby
kubectl get statefulset emby -n emby \
  -o jsonpath='{.spec.template.spec.volumes}{"\n"}'
kubectl exec -n emby statefulset/emby -c emby -- ls -lan /config
```

Expect one Ready Emby pod with `2/2` containers, Bound claims, a Ready certificate and a Service
backend in the EndpointSlice. Verify the config references `emby-config-iscsi`
and media references `emby-media`. The role's TCP
readiness probe confirms port 8096 responds; it is not a full database test.

Open the configured HTTPS hostname and complete Emby's first-run wizard.
Create the administrator account and add libraries under `/media` (or your
chosen media mount path). Play a file to verify media access.

To isolate Emby from proxy/DNS problems:

```bash
kubectl port-forward -n emby pod/emby-0 8096:8096
```

Open `http://127.0.0.1:8096` on the management machine. Press Ctrl+C to stop
forwarding. If browsing from another computer, use an SSH tunnel rather than
assuming its localhost is the management machine.

Your LAN Emby DNS record must resolve to `<emby-service-ip>`. The role
does not create DNS records or firewall/port-forwarding rules. DNS-01
certificate issuance can support a LAN-only application; a valid certificate
does not prove that an external client can reach the web service.

## 9. Troubleshoot by Layer

Start with current events:

```bash
kubectl get events -n emby --sort-by=.metadata.creationTimestamp
kubectl describe pvc emby-config-iscsi -n emby
kubectl describe pod -n emby -l app=emby
```

| Symptom | Next check |
| :--- | :--- |
| New PVC Pending before any consumer | Expected with delayed binding; the Emby StatefulSet provides the consumer. |
| Provisioning cannot find an available DSM host | Controller logs, DSM connectivity, TLS trust, credentials, storage location. |
| PVC Bound but pod stuck creating | Pod events for node registration, iSCSI/NFS login or mount errors. |
| iSCSI connection refused or timeout | NAS listener and TCP 3260 from the scheduled node through every firewall. |
| DSM certificate mismatch or unknown CA | Vault TLS hostname and CA settings; reload CSI plugins if needed. |
| Image pull failure | Exact tag, registry reachability, architecture and authentication. |
| Permission denied | Numeric ownership, UID/GID/GIDLIST, export permissions, read-only mounts. |
| Pod Ready but HTTPS fails | DNS, MetalLB announcement, proxy logs, Service endpoints and Certificate events. |
| Immutable selector error | Adapt the template to the existing selector rather than blindly deleting resources. |

Provisioning happens in the controller; mounting happens on the node:

```bash
kubectl logs -n synology-csi statefulset/synology-csi-controller \
  -c csi-plugin --tail=100
kubectl get pods -n synology-csi -o wide
```

Find the CSI node pod on the same node as Emby and substitute its name:

```bash
kubectl logs -n synology-csi <csi-node-pod-name> -c csi-plugin --tail=100
```

For host diagnostics, SSH into that node:

```bash
sudo journalctl -u iscsid --since '10 minutes ago' --no-pager
# On a K3s server:
sudo journalctl -u k3s --since '10 minutes ago' --no-pager
# On a K3s agent instead:
sudo journalctl -u k3s-agent --since '10 minutes ago' --no-pager
```

Do not format the LUN or remove iSCSI sessions while an application may be
using it. Increasing login retries does not fix a blocked port.


## 10. Routine Operation and Backups

Keep one replica. All pods produced by this role would reference the same
config claim, so scaling replicas is not a way to add Emby capacity.
The StatefulSet keeps the pod name `emby-0`; its headless governing Service
is `emby-headless`. Client traffic uses the separate ClusterIP Service `emby`.

The config PVC is declared separately from the StatefulSet, rather than in
`volumeClaimTemplates`. Its identity remains explicit and independent of
pod replacement. Deleting or restarting a pod does not delete its claim.

Before maintenance, take an application-consistent config backup. SQLite can
have committed data in WAL files; a filesystem copy should include the whole
config tree while Emby is stopped, rather than just the database file.
Store backups outside the NAS failure domain and test restoring them.

To stop the application for a maintenance window:

```bash
kubectl scale statefulset/emby -n emby --replicas=0
kubectl wait --for=delete pod/emby-0 -n emby --timeout=180s
```

Do not run the application playbook during maintenance: its desired replica
count is one. A completed stop means the pod is gone; investigate shutdown
timeouts rather than assuming a database writer has stopped.

When maintenance is complete, reconcile the desired state:

```bash
ansible-playbook playbooks/applications/emby.yml
kubectl rollout status statefulset/emby -n emby --timeout=300s
```

For more config capacity, increase `emby_config_storage_size` and rerun the
role if the StorageClass permits expansion. Verify the claim and filesystem
afterwards. Claims cannot be shrunk, and their StorageClass cannot be changed
in place.

Check the actual PV reclaim policy before removing storage resources:

```bash
kubectl get pv
```

With `Retain`, deleting a PVC leaves storage requiring deliberate recovery
or cleanup. A retained LUN is not an independent backup.

Persistence and node-loss recovery are separate. Confirm a failed node is
powered off or fenced before forcing another writer onto the config volume.
This Synology CSI setup does not provide storage fencing. Test recovery
separately once deployment is stable.

### Verify Movement Between Workers

For a planned test, first confirm a second eligible worker is Ready and has
working CSI plugins. Find the current worker with `kubectl get pod emby-0
-n emby -o wide`. Cordoning prevents new scheduling without evicting other
workloads. Replace the placeholder below with that worker's name:

```bash
kubectl cordon <current-emby-worker>
kubectl delete pod emby-0 -n emby
kubectl get pod emby-0 -n emby -o wide --watch
# After the replacement reaches 2/2 Ready, stop the watch with Ctrl+C.
kubectl get service emby -n emby
kubectl uncordon <current-emby-worker>
```

Verify HTTPS and playback using the same hostname and IP. Existing streams
will disconnect. Do not force-delete a pod on an unreachable node: fence
that node before allowing another writer to use the iSCSI config volume.
StatefulSets can wait for intervention after an ungraceful node failure;
this planned rescheduling test does not prove automatic crash recovery.
