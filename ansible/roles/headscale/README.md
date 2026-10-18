# Deploying Headscale on K3s

This role runs Headscale with an NGINX HTTPS sidecar and a dedicated MetalLB
service IP, using a certificate from `letsencrypt-production`. It is an
application deployment, separate from `playbooks/bootstrap-cluster.yml`.

## 1. Storage and Cluster Requirements

Run cluster bootstrap first. MetalLB and cert-manager must be ready, and the
Let's Encrypt production ClusterIssuer must be working. Headscale's service IP
must be reserved outside DHCP and available on the worker-node LAN.

Headscale uses SQLite and one replica. Its data claim uses the same Synology
iSCSI StorageClass as Emby's config claim, so the disk can detach from a failed
worker and attach to another worker. Synology iSCSI is block storage; SQLite's
database and WAL files are not stored on NFS.

SQLite WAL files must not be stored on an NFS share. The role checks that the
configured class is backed by Synology CSI with the iSCSI protocol. After the
first successful deployment, the role
sets the PV reclaim policy to `Retain` and prints its name. Save that name in
`headscale_data_pv` so the role can reattach the same data volume if its claim
is deleted. Retention protects the volume from claim deletion; it does not
replace backups.

One replica with `Recreate` avoids overlapping application instances during
normal updates. Node failure recovery still takes time for failure detection,
safe disk detachment and reattachment, and pod startup. Storage fencing must
prevent the old node and its replacement from writing simultaneously. Do not
force-delete a pod on a partitioned node without ensuring the old writer is stopped.

## 2. DNS and External Access

The default endpoint is `https://headscale.compvirt.com`, derived from `domain`.

1. Create a public DNS record for `headscale.compvirt.com` pointing to your
   public IP. In Cloudflare, use **DNS only**, not the orange-cloud proxy.
   Cloudflare Proxy and Tunnel do not support Headscale's control protocol.
2. Forward TCP 443 from the router to the worker-LAN address configured as
   `headscale_service_ip`. MetalLB advertises that address from the worker with
   the ready Headscale pod. The kube-vip address in this repository manages the
   Kubernetes API only.
3. If your router does not support NAT loopback, create a LAN DNS override for
   the same hostname pointing to `headscale_service_ip`.

If the ISP uses CGNAT and you cannot accept inbound connections, a public
forwarding endpoint or another ingress arrangement is required first.

NGINX terminates TLS inside the Headscale pod, then forwards HTTP to Headscale
over the pod's loopback interface on port 8080. The MetalLB Service uses
`externalTrafficPolicy: Local`, so client traffic reaches the worker with the
pod and does not traverse a control-plane node. The pod can move between
eligible workers; MetalLB then advertises the same service IP from its new
worker. Do not add browser authentication middleware in front of the client
control endpoint. Metrics and the remote admin gRPC listener remain bound to
loopback inside the Headscale container.

The embedded DERP server is disabled. Clients use the public Tailscale DERP map,
so this setup does not need inbound UDP 3478 for a Headscale-hosted relay. The
pod must be able to download the map and clients must be able to reach its relays.

## 3. Configuration

Put the reserved service address in encrypted
`inventory/group_vars/all/vault.yml`:

```yaml
headscale_service_ip: "<reserved-worker-lan-ip>"
```

| Variable | Default | Description |
| :--- | :--- | :--- |
| `headscale_hostname` | `headscale.{{ domain }}` | Public control-server hostname. |
| `headscale_version` | `0.29.4` | Pinned image release. |
| `headscale_storage_class` | `synology-iscsi-storage` | Synology CSI iSCSI block-storage class. |
| `headscale_data_pv` | Empty on first deployment | Pin the PV name printed by the first successful run to enable reattachment after claim deletion. |
| `headscale_service_ip` | Empty; required in Vault | Reserved LAN IP advertised by MetalLB. |
| `headscale_proxy_version` | `1.28.3-alpine` | Pinned NGINX sidecar image tag. |
| `headscale_storage_size` | `1Gi` | Requested database/key volume capacity. |
| `headscale_magic_dns_domain` | `tailnet.{{ domain }}` | Separate domain for device names. |
| `headscale_dns_override_local` | `false` | Preserve clients' existing DNS resolvers. |
| `headscale_dns_nameservers` | `[]` | Optional global resolvers for clients. |
| `headscale_dns_split` | `{}` | Optional domain-specific DNS resolvers. |
| `headscale_node_expiry` | `180d` | Default personal-device key lifetime. |
| `headscale_wait_timeout` | `300` | Readiness timeout in seconds. |

The default policy allows personal devices owned by the **same Headscale user**
to communicate. It does not grant cross-user access, tagged-device access,
subnet routes, or exit-node use. Override `headscale_policy` when those are needed.

Headscale coordinates Tailscale clients; deploying it does not automatically
give remote clients access to the LAN or Kubernetes networks. That requires
a separately configured subnet router and an appropriate policy.

## 4. Deployment and Verification

From the repository root, with the existing Ansible environment activated:

```bash
cd ansible
ansible-playbook playbooks/applications/headscale.yml --syntax-check
ansible-playbook playbooks/applications/headscale.yml
```

The role creates the namespace, MetalLB address pool and advertisement,
certificate, configuration, PVC, Deployment and LoadBalancer Service, then
waits for the application and certificate. Configuration, policy and proxy
checksums trigger a restart when those files change. Repeated runs with the
same settings should leave the resources unchanged. Check mode skips rollout
and certificate waits; the storage, MetalLB and issuer preflight reads still
require a reachable cluster.

After the first deployment, copy the `headscale_data_pv` value printed by the
role into `inventory/group_vars/all/vars.yml`. The role then pins the PVC to
that PV on later runs. If the namespace or claim is deleted, wait until
Kubernetes has finished deleting it, keep the PV pin, and rerun the playbook;
the role reclaims the released PV for `headscale-data`. If the PV object itself
has also been deleted, this automatic reattachment cannot recover it.

```bash
kubectl get pod,pvc,svc,certificate -n headscale
kubectl get ipaddresspool,l2advertisement -n metallb-system headscale
kubectl logs -n headscale deployment/headscale
kubectl logs -n headscale deployment/headscale -c https-proxy
curl --fail https://headscale.compvirt.com/health
```

Test HTTPS from outside your LAN as well as inside. A valid certificate and
healthy pod do not by themselves prove public routing or client registration.

## 5. Registering Devices

Use Tailscale clients version 1.80.0 or newer. Create a user once, then list users:

```bash
kubectl exec -n headscale deployment/headscale -- headscale users create donald
kubectl exec -n headscale deployment/headscale -- headscale users list
```

On the client:

```bash
sudo tailscale up --login-server https://headscale.compvirt.com
```

Follow the displayed registration URL. Approve its Auth ID from the management
machine, replacing the placeholder with the ID shown on the registration page:

```bash
kubectl exec -n headscale deployment/headscale -- headscale auth register --user donald --auth-id YOUR_AUTH_ID
kubectl exec -n headscale deployment/headscale -- headscale nodes list
```

Register a second device under the same user and test communication between
their tailnet addresses. Users and auth keys are deliberately not recreated on
each Ansible run. Use the CLI through `kubectl exec`; no public admin UI is installed.

## 6. Backups and Recovery

Back up the complete `/var/lib/headscale` volume, including the SQLite database
and Noise private key, using a consistent database backup or a snapshot taken
while Headscale is stopped. Copying only the live `db.sqlite` file may omit
transactions in its WAL. Store backups outside the storage failure domain.
Keep the Ansible configuration and policy alongside your recovery documentation.

Replicated storage is not a backup. Test restore and node-loss recovery before
depending on the service. Headscale remains single-replica even when the storage
is replicated. Never increase the replica count to make SQLite highly available.

For image upgrades, follow Headscale's supported release-by-release upgrade
path and back up first; a database migration may prevent simply downgrading the
image. A deployment restart can interrupt coordination while clients reconnect.

References: [Headscale configuration](https://github.com/juanfont/headscale/blob/v0.29.4/config-example.yaml),
[reverse proxy requirements](https://headscale.net/stable/ref/integration/reverse-proxy/),
[device registration](https://headscale.net/stable/usage/getting-started/),
[SQLite WAL restrictions](https://www.sqlite.org/wal.html).
