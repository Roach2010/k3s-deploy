#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_STEPS=9
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

parse_args "$@"

ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/deploy.env}"
OUT_DIR="${SCRIPT_DIR}/rendered"
mkdir -p "${OUT_DIR}"

load_env "${ENV_FILE}"

validate_vars \
  GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_INSECURE \
  DS_CLUSTER NETWORK VM_FOLDER DOMAIN_SUFFIX \
  SSH_PUBLIC_KEY_1 K3S_TOKEN CONTROL_PLANE_IP K3S_VERSION \
  CLUSTER_CIDR SERVICE_CIDR

ensure_fcos_ova "${FCOS_STREAM:-stable}" "${SCRIPT_DIR}/ova"

FQDN="${VM_NAME}.${DOMAIN_SUFFIX}"

if [[ "${CLUSTER_INIT}" == true && "${JOIN_CLUSTER}" == true ]]; then
  echo "--cluster-init/-c and --join/-j are mutually exclusive."
  echo "Use --cluster-init on the first HA control-plane node only;"
  echo "use --join on every additional one."
  exit 1
fi

if [[ "${CLUSTER_INIT}" == true ]]; then
  CP_EXTRA_FLAG="--cluster-init"
  CP_MODE="cluster-init (new HA cluster)"
elif [[ "${JOIN_CLUSTER}" == true ]]; then
  CP_EXTRA_FLAG="--server https://${CONTROL_PLANE_IP}:6443"
  CP_MODE="join (additional HA node)"
else
  CP_EXTRA_FLAG=""
  CP_MODE="single-node (sqlite)"
fi

TLS_SAN_FLAGS=$(build_tls_san_flags "${CONTROL_PLANE_IP}${EXTRA_TLS_SAN:+,${EXTRA_TLS_SAN}}")

render_ignition "${SCRIPT_DIR}/fcos-k3s-controlplane.bu" "${OUT_DIR}" "${VM_NAME}" \
  -e "s|__HOSTNAME__|${FQDN}|g" \
  -e "s|__SSH_PUBLIC_KEY_1__|${SSH_PUBLIC_KEY_1}|g" \
  -e "s|__K3S_TOKEN__|${K3S_TOKEN}|g" \
  -e "s|__K3S_VERSION__|${K3S_VERSION}|g" \
  -e "s|__CLUSTER_CIDR__|${CLUSTER_CIDR}|g" \
  -e "s|__SERVICE_CIDR__|${SERVICE_CIDR}|g" \
  -e "s|__TLS_SAN_FLAGS__|${TLS_SAN_FLAGS}|g" \
  -e "s|__CP_EXTRA_FLAG__|${CP_EXTRA_FLAG}|g" \
  -e "s|__CP_MODE__|${CP_MODE}|g"

select_datastore "${DS_CLUSTER}"
build_import_options "${FCOS_OVA}" "${NETWORK}" "${OUT_DIR}/${VM_NAME}-import-options.json"
import_vm "${DATASTORE}" "${VM_NAME}" "${OPTIONS_FILE}" "${FCOS_OVA}" "${VM_FOLDER}"
resolve_mac "${VM_NAME}"

echo "Add a DHCP reservation: ${VM_MAC} -> ${CONTROL_PLANE_IP}"
maybe_wait_for_reservation

inject_and_power_on "${VM_NAME}" "${CONFIG_ENCODING}" "${CONFIG_ENCODED}"

echo ""
echo "Deployed ${VM_NAME}. Once booted:"
echo "  ssh core@${CONTROL_PLANE_IP}"
echo "  sudo cat /etc/rancher/k3s/k3s.yaml   # kubeconfig"
echo "Note: the node reboots itself once to finalize the open-vm-tools layer,"
echo "after k3s bootstrap has completed successfully."
