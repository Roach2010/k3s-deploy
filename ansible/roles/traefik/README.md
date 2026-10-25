# Traefik Ingress

K3s installs Traefik as a bundled Helm chart. This role configures its existing
LoadBalancer Service to use MetalLB's reserved IP address and
`externalTrafficPolicy: Local`. Local traffic policy preserves client source
addresses for Ingress middleware such as AdGuard Home's LAN-only allow-list.

K3s ServiceLB must be disabled on every K3s server before MetalLB manages the
Traefik Service. The FCOS control-plane template includes this setting for new
nodes. On an existing cluster, add `disable: [servicelb]` to
`/etc/rancher/k3s/config.yaml` on every control-plane node, then restart the
servers one at a time and wait for each to return Ready before continuing.

Run cluster bootstrap from `ansible/` after MetalLB is installed and
ServiceLB is disabled:

Edit the encrypted vault and add the reserved address:

```bash
ansible-vault edit inventory/group_vars/all/vault.yml
```

Add this key to the vault file:

```yaml
traefik_service_ip: "x.x.x.x"
```

Then apply the role:

```bash
ansible-playbook playbooks/bootstrap-cluster.yml --tags traefik
kubectl get service traefik -n kube-system -o wide
kubectl get ipaddresspool,l2advertisement -n metallb-system
```

The existing Service is recreated on the first role run because Kubernetes
does not allow changing `loadBalancerClass` in place. The Traefik Ingress DNS
records should use only one IP; the K3s API VIP remains using another.
The Service uses the MetalLB class and a dedicated `/32` pool, so other
LoadBalancer Services cannot claim this address.
