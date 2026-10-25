# Deploying AdGuard Home on K3s with Ansible

This role deploys AdGuard Home as a single-replica StatefulSet. A dedicated
MetalLB LoadBalancer exposes plain DNS on a stable LAN IP, while Traefik serves
the HTTPS management UI through an Ingress restricted to the configured LAN
CIDRs. Configuration and working data use Synology iSCSI storage.

## 1. Requirements and Network Design

Run cluster bootstrap first. The role requires the Synology CSI iSCSI
StorageClass, MetalLB, cert-manager, the production ClusterIssuer, and K3s
Traefik with its Middleware CRD.

The DNS Service listens on both TCP and UDP port 53 and advertises
`adguard_home_dns_service_ip` from the worker running the pod. The StatefulSet
can move between eligible workers because its `ReadWriteOnce` claim is backed
by Synology iSCSI. `externalTrafficPolicy: Local` keeps client DNS traffic on
that worker. This must be a separate address from the K3s API VIP: kube-vip
owns the API address for the control plane, while MetalLB advertises this DNS
address for AdGuard. Reusing the API VIP would cause competing ownership and
would not route DNS traffic to the AdGuard pod. Reserve an unused service
address outside DHCP, within MetalLB's layer-2 network, and route the client
LAN to it. Permit TCP and UDP 53 from client networks and TCP/UDP 7946 between
MetalLB speakers. Do not forward port 53 from the Internet; AdGuard Home is
intended to provide DNS to your LAN.

The container runs as UID 0 because AdGuard Home requires administrator rights
on its first launch. The pod drops all Linux capabilities except
`NET_BIND_SERVICE`, disables privilege escalation, and uses a read-only root
filesystem; persistent config and work files remain on the dedicated claim.

The management UI uses the existing Traefik entry point and the
`letsencrypt-production` ClusterIssuer. A Traefik IP allow-list middleware
restricts the Ingress to `adguard_home_lan_cidrs`. Configure local DNS so
`adguard.<your-domain>` resolves to Traefik's MetalLB VIP.
Do not point this record to the separate AdGuard DNS LoadBalancer IP.
The certificate uses the existing DNS-01 issuer, so the hostname does not need
a public A record.

## 2. Configure the Role

The role defaults pin the official stable image release and set the namespace,
storage, hostname, web port, and allowed LAN CIDRs. Review these settings in
`roles/adguard_home/defaults/main.yml`.

Put the reserved DNS service IP in encrypted
`inventory/group_vars/all/vault.yml`:

```yaml
adguard_home_dns_service_ip: "<reserved-lan-ip>"
```

The PV name is learned after the first deployment and saved in
`inventory/group_vars/all/vars.yml` as `adguard_home_data_pv`. This pin enables
reattachment if the PVC is deleted.

## 3. Deploy AdGuard Home

Run from the `ansible/` directory:

```bash
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbooks/applications/adguard-home.yml --syntax-check
ansible-playbook playbooks/applications/adguard-home.yml
```

The role checks that the storage class is Synology iSCSI, that an eligible
worker and MetalLB are available, and that Traefik, its Middleware CRD, and the
certificate issuer are installed. It creates the namespace, claim, DNS
address pool, Traefik allow-list, certificate, Ingress, StatefulSet, and
Services. The role waits for the certificate, storage claim, pod, and DNS IP.
After the first deployment it changes the PV reclaim policy to `Retain` and
prints the PV name to pin.

AdGuard Home's first-run wizard listens on port 3000. The role exposes both
that setup port and the management UI port (80), and its probes accept either
port so completing the wizard does not cause Kubernetes to restart the pod.
Forward the setup port locally to configure AdGuard Home without depending on
local DNS or exposing the wizard through the Internet:

```bash
kubectl port-forward -n adguard-home pod/adguard-home-0 3000:3000
```

Open `http://127.0.0.1:3000`. In the wizard, configure the web interface to
listen on `0.0.0.0:80` so the Traefik service can reach the management UI. Set
the DNS server to listen on `0.0.0.0:53`, create a strong admin account, and
choose upstream resolvers and filtering lists. The settings and query data
persist on the Synology volume.

After setup, set your router's DHCP DNS option to the AdGuard service IP (or
configure selected clients manually). Avoid advertising a public secondary
resolver if you want clients to consistently use AdGuard. Verify DNS from a
client:

```bash
nslookup example.com <adguard-dns-service-ip>
dig @<adguard-dns-service-ip> example.com
```

Then open `https://adguard.<your-domain>` for the management UI. The LAN DNS
record for that name must point to the Traefik endpoint, while the separate
DNS service IP remains the address clients use for DNS queries.

## 4. Verify and Maintain

Check the application and networking resources:

```bash
kubectl get statefulset,pods,pvc,svc,ingress -n adguard-home
kubectl get certificate -n adguard-home
kubectl get middleware -n adguard-home
kubectl logs -n adguard-home adguard-home-0
```

The DNS LoadBalancer should show the reserved IP and TCP/UDP port 53. The
Ingress should use class `traefik`, have a ready certificate, and resolve the
LAN-only middleware. If a permitted client is denied, verify the client source
address that Traefik sees and adjust `adguard_home_lan_cidrs` if needed.

Back up the Synology volume or take NAS snapshots. `Retain` protects data from
PVC deletion, but does not replace backups. Keep one replica: all instances
share one configuration and working-data claim.
