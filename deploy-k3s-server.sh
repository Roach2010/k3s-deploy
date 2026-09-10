#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_STEPS=9
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

parse_args "$@"

if [[ "${CLUSTER_INIT}" == true || "${JOIN_CLUSTER}" == true ]]; then
  echo "--cluster-init/-c and --join/-j don't apply to deploy-k3s-server.sh."
  echo "It always joins the existing HA cluster at CONTROL_PLANE_IP - that"
  echo "behavior isn't optional here, unlike deploy-controlplane.sh."
  exit 1
fi

ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/deploy.env}"
OUT_DIR="${SCRIPT_DIR}/rendered"
mkdir -p "${OUT_DIR}"

load_env "${ENV_FILE}"

validate_vars \
  GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_INSECURE \
  DS_CLUSTER NETWORK VM_FOLDER DOMAIN_SUFFIX \
  SSH_PUBLIC_KEY_1 K3S_TOKEN CONTROL_PLANE_IP K3S_VERSION \
  CLUSTER_CIDR SERVICE_CIDR NEW_SERVER_TLS_SAN

ensure_fcos_ova "${FCOS_STREAM:-stable}" "${SCRIPT_DIR}/ova"

FQDN="${VM_NAME}.${DOMAIN_SUFFIX}"

TLS_SAN_FLAGS=$(build_tls_san_flags "${NEW_SERVER_TLS_SAN}")

render_ignition "${SCRIPT_DIR}/fcos-k3s-server.bu" "${OUT_DIR}" "${VM_NAME}" \
  -e "s|__HOSTNAME__|${FQDN}|g" \
  -e "s|__SSH_PUBLIC_KEY_1__|${SSH_PUBLIC_KEY_1}|g" \
  -e "s|__K3S_TOKEN__|${K3S_TOKEN}|g" \
  -e "s|__CONTROL_PLANE_IP__|${CONTROL_PLANE_IP}|g" \
  -e "s|__K3S_VERSION__|${K3S_VERSION}|g" \
  -e "s|__CLUSTER_CIDR__|${CLUSTER_CIDR}|g" \
  -e "s|__SERVICE_CIDR__|${SERVICE_CIDR}|g" \
  -e "s|__NEW_SERVER_TLS_SAN__|${NEW_SERVER_TLS_SAN}|g" \
  -e "s|__TLS_SAN_FLAGS__|${TLS_SAN_FLAGS}|g"

select_datastore "${DS_CLUSTER}"
build_import_options "${FCOS_OVA}" "${NETWORK}" "${OUT_DIR}/${VM_NAME}-import-options.json"
import_vm "${DATASTORE}" "${VM_NAME}" "${OPTIONS_FILE}" "${FCOS_OVA}" "${VM_FOLDER}"
resolve_mac "${VM_NAME}"

echo "If you want a fixed IP for ${VM_NAME}, add a DHCP reservation for ${VM_MAC} now."
echo "(This node's own TLS SAN is set to NEW_SERVER_TLS_SAN=${NEW_SERVER_TLS_SAN}.)"
maybe_wait_for_reservation

inject_and_power_on "${VM_NAME}" "${CONFIG_ENCODING}" "${CONFIG_ENCODED}"

echo ""
echo "Deployed ${VM_NAME} as an additional control-plane node,"
echo "joining the existing HA cluster at https://${CONTROL_PLANE_IP}:6443."
echo "This only works if that cluster was created with --cluster-init"
echo "(embedded etcd) - see the README's HA section if it wasn't."
echo "Once booted:"
echo "  ssh core@<its-IP>"
echo "  sudo cat /etc/rancher/k3s/k3s.yaml   # kubeconfig (server: https://127.0.0.1:6443 - see README)"
echo "Note: the node reboots itself once to finalize the open-vm-tools layer,"
echo "after k3s bootstrap has completed successfully."
