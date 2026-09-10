#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_STEPS=9
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

parse_args "$@"

if [[ "${CLUSTER_INIT}" == true || "${JOIN_CLUSTER}" == true ]]; then
  echo "--cluster-init/-c and --join/-j only apply to deploy-controlplane.sh, not workers."
  exit 1
fi

ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/deploy.env}"
OUT_DIR="${SCRIPT_DIR}/rendered"
mkdir -p "${OUT_DIR}"

load_env "${ENV_FILE}"

validate_vars \
  GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_INSECURE \
  DS_CLUSTER NETWORK VM_FOLDER DOMAIN_SUFFIX \
  SSH_PUBLIC_KEY_1 K3S_TOKEN CONTROL_PLANE_IP K3S_VERSION

ensure_fcos_ova "${FCOS_STREAM:-stable}" "${SCRIPT_DIR}/ova"

FQDN="${VM_NAME}.${DOMAIN_SUFFIX}"

render_ignition "${SCRIPT_DIR}/fcos-k3s-worker.bu" "${OUT_DIR}" "${VM_NAME}" \
  -e "s|__HOSTNAME__|${FQDN}|g" \
  -e "s|__SSH_PUBLIC_KEY_1__|${SSH_PUBLIC_KEY_1}|g" \
  -e "s|__K3S_TOKEN__|${K3S_TOKEN}|g" \
  -e "s|__CONTROL_PLANE_IP__|${CONTROL_PLANE_IP}|g" \
  -e "s|__K3S_VERSION__|${K3S_VERSION}|g"

select_datastore "${DS_CLUSTER}"
build_import_options "${FCOS_OVA}" "${NETWORK}" "${OUT_DIR}/${VM_NAME}-import-options.json"
import_vm "${DATASTORE}" "${VM_NAME}" "${OPTIONS_FILE}" "${FCOS_OVA}" "${VM_FOLDER}"
resolve_mac "${VM_NAME}"

echo "If you want a fixed IP for ${VM_NAME}, add a DHCP reservation for ${VM_MAC} now."
maybe_wait_for_reservation

inject_and_power_on "${VM_NAME}" "${CONFIG_ENCODING}" "${CONFIG_ENCODED}"

echo ""
echo "Deployed ${VM_NAME}. It will join ${CONTROL_PLANE_IP} once k3s server is reachable."
echo "Note: the node reboots itself once to finalize the open-vm-tools layer,"
echo "after k3s agent bootstrap has completed successfully."
