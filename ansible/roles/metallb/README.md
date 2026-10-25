# MetalLB for Dedicated Application Addresses

The cluster bootstrap installs MetalLB in layer-2 mode. Its controller and
speakers manage services with `loadBalancerClass: metallb.io/metallb`.
K3s ServiceLB must be disabled on every server because it does not honor the
Kubernetes load-balancer class and would compete with MetalLB. New servers get
the setting from `fcos-k3s-controlplane.bu`; existing servers need
`disable: [servicelb]` in `/etc/rancher/k3s/config.yaml` and a rolling restart.
Merge the setting into existing YAML on every control-plane node; do not add
a duplicate `disable` key. Apply the setting to all servers before restarting
any, then restart them one at a time and wait for each to become Ready. The
kube-vip API address remains separate and unchanged.

Run from `ansible/`:

```bash
ansible-playbook playbooks/bootstrap-cluster.yml --tags metallb
kubectl get pods -n metallb-system -o wide
```

After ServiceLB is disabled on an existing cluster, configure Traefik's
reserved VIP with:

```bash
ansible-playbook playbooks/bootstrap-cluster.yml --tags traefik
kubectl get service traefik -n kube-system -o wide
```

The chart version lives in `defaults/main.yml`. Helm waits for readiness;
FRR and FRR-K8s are disabled because this role uses ARP rather than BGP.
The namespace permits the privileged network speaker pods.

Application roles create their address pools and advertisements after the
controller is ready. Traefik reserves it's IP, while other
applications reserve their own addresses with automatic allocation disabled.
Services using `externalTrafficPolicy: Local` are announced from a node with a
ready local endpoint.

Reserve service IPs outside DHCP and do not configure them on host interfaces.
Eligible nodes must share the address's layer-2 network. Permit ARP, service
ports from clients, and TCP/UDP 7946 between speaker nodes. IPVS kube-proxy
configurations require strict ARP. Verify a working speaker runs on each
worker that may host Emby, and do not label those workers with
`node.kubernetes.io/exclude-from-external-load-balancers`.

Check the selected controller and allocated address:

```bash
kubectl get service emby -n emby -o yaml
kubectl get ipaddresspool,l2advertisement -n metallb-system
kubectl describe service emby -n emby
kubectl get daemonset -n kube-system -l svccontroller.k3s.cattle.io/svcname=emby
```

The Emby Service should show the explicit MetalLB class and `<emby-service-ip>`.
There should be no K3s ServiceLB DaemonSet for Emby. IP allocation alone does
not verify ARP reachability: test HTTPS from a client on the network.

See [MetalLB installation](https://metallb.io/installation/),
[traffic policies](https://metallb.io/usage/), and
[Kubernetes load-balancer classes](https://kubernetes.io/docs/concepts/services-networking/service/#load-balancer-class).
