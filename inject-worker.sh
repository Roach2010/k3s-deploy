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
  echo "Usage: $0 <hostname> [--power-on|-p]"
  exit 1
fi
VM_NAME=$1
shift

POWER_ON=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --power-on|-p)
      POWER_ON=true
      ;;
    --cluster-init|-c|--join|-j)
      echo "--cluster-init/-c and --join/-j only apply to inject-controlplane.sh, not workers."
      exit 1
      ;; 
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 <hostname> [--power-on|-p]"
      exit 1
      ;;
  esac
  shift
done

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
  DOMAIN_SUFFIX SSH_PUBLIC_KEY_1 K3S_TOKEN KUBE_API_HOSTNAME K3S_VERSION
)
for v in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "Missing required variable '${v}' in ${ENV_FILE}"
    exit 1
  fi
done
export GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_INSECURE
echo "All required variables present."

# --- Render Butane -> Ignition -------------------------------------------
FQDN="${VM_NAME}.${DOMAIN_SUFFIX}"

step "Rendering Butane template and compiling to Ignition"
sed \
  -e "s|__HOSTNAME__|${FQDN}|g" \
  -e "s|__SSH_PUBLIC_KEY_1__|${SSH_PUBLIC_KEY_1}|g" \
  -e "s|__K3S_TOKEN__|${K3S_TOKEN}|g" \
  -e "s|__KUBE_API_HOSTNAME__|${KUBE_API_HOSTNAME}|g" \
  -e "s|__K3S_VERSION__|${K3S_VERSION}|g" \
  "${SCRIPT_DIR}/fcos-k3s-worker.bu" > "${OUT_DIR}/${VM_NAME}.bu"

butane --pretty --strict "${OUT_DIR}/${VM_NAME}.bu" > "${OUT_DIR}/${VM_NAME}.ign"

CONFIG_ENCODING=base64
CONFIG_ENCODED=$(base64 -w0 "${OUT_DIR}/${VM_NAME}.ign")
echo "Ignition config ready: ${OUT_DIR}/${VM_NAME}.ign"

# --- Verify the target VM already exists ---------------------------------
step "Verifying '${VM_NAME}' exists in vSphere"
if ! govc vm.info -json "${VM_NAME}" 2>/dev/null | jq -e '.virtualMachines | length > 0' > /dev/null; then
  echo "No VM named '${VM_NAME}' found. This script only injects into an"
  echo "already-existing VM - use deploy-worker.sh to import a new one."
  exit 1
fi
echo "Found."

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
echo "(deploy-worker.sh)."
if [[ "${POWER_ON}" != true ]]; then
  echo "Not powered on (pass --power-on/-p to do that automatically)."
  echo "Power on manually when ready: govc vm.power -on ${VM_NAME}"
fi
