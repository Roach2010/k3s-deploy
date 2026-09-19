#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Progress output ---------------------------------------------------
STEP=0
TOTAL_STEPS=5
step() {
  STEP=$((STEP + 1))
  echo ""
  echo "==> [${STEP}/${TOTAL_STEPS}] $1"
}

# --- Argument parsing ----------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <hostname> [--wait-for-reservation|-w] [--cluster-init|-c] [--join|-j] [--node|-n <1|2|3>] [--power-on|-p]"
  exit 1
fi
VM_NAME=$1
shift

WAIT_FOR_RESERVATION=false
CLUSTER_INIT=false
JOIN_CLUSTER=false
NODE_NUMBER=""
POWER_ON=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait-for-reservation|-w)
      WAIT_FOR_RESERVATION=true
      ;;
    --cluster-init|-c)
      CLUSTER_INIT=true
      ;;
    --join|-j)
      JOIN_CLUSTER=true
      ;;
    --node|-n)
      shift
      NODE_NUMBER="${1:-}"
      ;;
    --power-on|-p)
      POWER_ON=true
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 <hostname> [--wait-for-reservation|-w] [--cluster-init|-c] [--join|-j] [--node|-n <1|2|3>] [--power-on|-p]"
      exit 1
      ;;
  esac
  shift
done

case "${NODE_NUMBER}" in
  ""|1|2|3)
    ;;
  *)
    echo "Invalid --node/-n value: '${NODE_NUMBER}' (must be 1, 2, or 3)"
    exit 1
    ;;
esac

if [[ "${CLUSTER_INIT}" == true && "${JOIN_CLUSTER}" == true ]]; then
  echo "--cluster-init/-c and --join/-j are mutually exclusive."
  echo "Use --cluster-init on the first HA control-plane node only;"
  echo "use --join on every additional one."
  exit 1
fi

ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/deploy.env}"
OUT_DIR="${SCRIPT_DIR}/rendered"
mkdir -p "${OUT_DIR}"

# --- Load and validate configuration ------------------------------------
# Only what's needed to render Butane/Ignition and talk to govc - no
# DS_CLUSTER/NETWORK/VM_FOLDER/FCOS_OVA, since nothing gets imported here.
step "Loading configuration from ${ENV_FILE}"
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}"
  echo "Copy deploy.env.example to deploy.env and fill in real values first."
  exit 1
fi
# shellcheck disable=SC1090
source "${ENV_FILE}"
echo "Loaded."

step "Validating required variables"
REQUIRED_VARS=(
  GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_INSECURE
  DOMAIN_SUFFIX SSH_PUBLIC_KEY_1 K3S_TOKEN K3S_VERSION
  CLUSTER_CIDR SERVICE_CIDR KUBE_API_HOSTNAME
  CP1_IP CP1_NAME CP2_IP CP2_NAME CP3_IP CP3_NAME
  NFS_CSI_DRIVER_VERSION
  KUBE_VIP KUBE_VIP_INTERFACE KUBE_VIP_VERSION)

for v in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "Missing required variable '${v}' in ${ENV_FILE}"
    exit 1
  fi
done
# Validate values before rendering them into shell commands and YAML.
if [[ ! "${KUBE_VIP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  echo "KUBE_VIP must be an IPv4 address."
  exit 1
fi
IFS='.' read -ra VIP_OCTETS <<< "${KUBE_VIP}"
for octet in "${VIP_OCTETS[@]}"; do
  if (( 10#${octet} > 255 )); then
    echo "Invalid KUBE_VIP octet: ${octet}"
    exit 1
  fi
done
if [[ "${KUBE_VIP}" == "${CP1_IP}" || "${KUBE_VIP}" == "${CP2_IP}" || "${KUBE_VIP}" == "${CP3_IP}" ]]; then
  echo "KUBE_VIP must be different from all control-plane node IPs."
  exit 1
fi
if [[ ! "${KUBE_VIP_INTERFACE}" =~ ^[a-zA-Z0-9_.:-]{1,15}$ || ! "${KUBE_VIP_VERSION}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Set a valid KUBE_VIP_INTERFACE and a pinned KUBE_VIP_VERSION (vX.Y.Z)."
  exit 1
fi
export GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_INSECURE
echo "All required variables present."

# --- Work out this node's k3s server mode -------------------------------
FQDN="${VM_NAME}.${DOMAIN_SUFFIX}"

if [[ "${CLUSTER_INIT}" == true ]]; then
  CP_EXTRA_FLAG="--cluster-init"
  CP_MODE="cluster-init (new HA cluster)"
elif [[ "${JOIN_CLUSTER}" == true ]]; then
  CP_EXTRA_FLAG="--server https://${KUBE_VIP}:6443"
  CP_MODE="join (additional HA node)"
else
  CP_EXTRA_FLAG=""
  CP_MODE="single-node (sqlite)"
fi

# Only install csi-driver-nfs on the node that creates the cluster
# (single-node or --cluster-init) - not on --join nodes, to avoid running
# the same cluster-wide install concurrently from multiple nodes.
if [[ "${JOIN_CLUSTER}" == true ]]; then
  INSTALL_CSI_DRIVER="false"
else
  INSTALL_CSI_DRIVER="true"
fi

# Expand a comma-separated SAN list into repeated --tls-san=... flags,
# trimming whitespace around each entry. k3s supports --tls-san multiple
# times. Every control-plane node's cert gets the SAME full set - all
# three CP IPs, all three CP DNS names (hostnames from deploy.env
# with DOMAIN_SUFFIX appended, same as this script's own FQDN above), and
# the shared KUBE_API_HOSTNAME - regardless of which node is currently
# being deployed, plus whatever EXTRA_TLS_SAN adds on top.
SAN_CSV="${CP1_IP},${CP2_IP},${CP3_IP},${CP1_NAME}.${DOMAIN_SUFFIX},${CP2_NAME}.${DOMAIN_SUFFIX},${CP3_NAME}.${DOMAIN_SUFFIX},${KUBE_API_HOSTNAME},${KUBE_VIP}${EXTRA_TLS_SAN:+,${EXTRA_TLS_SAN}}"
TLS_SAN_FLAGS=""
IFS=',' read -ra SAN_VALUES <<< "${SAN_CSV}"
for san in "${SAN_VALUES[@]}"; do
  san="${san#"${san%%[![:space:]]*}"}"
  san="${san%"${san##*[![:space:]]}"}"
  [[ -n "${san}" ]] && TLS_SAN_FLAGS+="--tls-san=${san} "
done

# Which of the three control-plane IPs applies to *this* deployment,
# for the informational messages below. Defaults to node 1's IP when
# --node isn't given, matching this script's original behavior.
case "${NODE_NUMBER}" in
  2) THIS_NODE_IP="${CP2_IP}" ;;
  3) THIS_NODE_IP="${CP3_IP}" ;;
  *) THIS_NODE_IP="${CP1_IP}" ;;
esac

# --- Render Butane -> Ignition -------------------------------------------
step "Rendering Butane template and compiling to Ignition"
sed \
  -e "s|__HOSTNAME__|${FQDN}|g" \
  -e "s|__SSH_PUBLIC_KEY_1__|${SSH_PUBLIC_KEY_1}|g" \
  -e "s|__K3S_TOKEN__|${K3S_TOKEN}|g" \
  -e "s|__K3S_VERSION__|${K3S_VERSION}|g" \
  -e "s|__CLUSTER_CIDR__|${CLUSTER_CIDR}|g" \
  -e "s|__SERVICE_CIDR__|${SERVICE_CIDR}|g" \
  -e "s|__TLS_SAN_FLAGS__|${TLS_SAN_FLAGS}|g" \
  -e "s|__CP_EXTRA_FLAG__|${CP_EXTRA_FLAG}|g" \
  -e "s|__CP_MODE__|${CP_MODE}|g" \
  -e "s|__KUBE_API_HOSTNAME__|${KUBE_API_HOSTNAME}|g" \
  -e "s|__KUBE_VIP__|${KUBE_VIP}|g" \
  -e "s|__KUBE_VIP_INTERFACE__|${KUBE_VIP_INTERFACE}|g" \
  -e "s|__KUBE_VIP_VERSION__|${KUBE_VIP_VERSION}|g" \
  -e "s|__INSTALL_CSI_DRIVER__|${INSTALL_CSI_DRIVER}|g" \
  -e "s|__NFS_CSI_DRIVER_VERSION__|${NFS_CSI_DRIVER_VERSION}|g" \
  "${SCRIPT_DIR}/fcos-k3s-controlplane.bu" > "${OUT_DIR}/${VM_NAME}.bu"

butane --pretty --strict "${OUT_DIR}/${VM_NAME}.bu" > "${OUT_DIR}/${VM_NAME}.ign"

CONFIG_ENCODING=base64
CONFIG_ENCODED=$(base64 -w0 "${OUT_DIR}/${VM_NAME}.ign")
echo "Ignition config ready: ${OUT_DIR}/${VM_NAME}.ign"

# --- Verify the target VM already exists ---------------------------------
step "Verifying '${VM_NAME}' exists in vSphere"
if ! govc vm.info -json "${VM_NAME}" 2>/dev/null | jq -e '.virtualMachines | length > 0' > /dev/null; then
  echo "No VM named '${VM_NAME}' found. This script only injects into an"
  echo "already-existing VM - use deploy-controlplane.sh to import a new one."
  exit 1
fi
echo "Found."

VM_MAC=$(govc vm.info -json "${VM_NAME}" \
  | jq -r '.virtualMachines[0].config.hardware.device[] | select(.macAddress != null) | .macAddress' \
  | head -1)
echo "VM MAC address: ${VM_MAC}"
echo "Add a DHCP reservation: ${VM_MAC} -> ${THIS_NODE_IP}"
if [[ "${WAIT_FOR_RESERVATION}" == true ]]; then
  read -r -p "Press Enter once the DHCP reservation has been added to continue... "
fi

# --- Inject Ignition -------------------------------------------------------
step "Injecting Ignition config"
govc vm.change -vm "${VM_NAME}" \
  -e "guestinfo.ignition.config.data.encoding=${CONFIG_ENCODING}" \
  -e "guestinfo.ignition.config.data=${CONFIG_ENCODED}"
echo "Injected."

if [[ "${POWER_ON}" == true ]]; then
  govc vm.power -on "${VM_NAME}"
  echo "Powered on."
fi

echo ""
echo "Ignition config injected into ${VM_NAME}."
echo "IMPORTANT: Ignition only applies on a VM's very first boot. If this"
echo "VM has already been powered on before, injecting new guestinfo here"
echo "will NOT retroactively apply it - re-import a fresh VM instead"
echo "(deploy-controlplane.sh)."
if [[ "${POWER_ON}" != true ]]; then
  echo "Not powered on (pass --power-on/-p to do that automatically)."
  echo "Power on manually when ready: govc vm.power -on ${VM_NAME}"
fi
