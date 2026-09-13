#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Progress output ---------------------------------------------------
STEP=0
TOTAL_STEPS=9
step() {
  STEP=$((STEP + 1))
  echo ""
  echo "==> [${STEP}/${TOTAL_STEPS}] $1"
}

# --- Argument parsing ----------------------------------------------------
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <hostname>"
  exit 1
fi
VM_NAME=$1
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-init|-c|--join|-j)
      echo "--cluster-init/-c and --join/-j only apply to deploy-controlplane.sh, not workers."
      exit 1
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 <hostname>"
      exit 1
      ;;
  esac
  shift
done

ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/deploy.env}"
OUT_DIR="${SCRIPT_DIR}/rendered"
mkdir -p "${OUT_DIR}"

# --- Load and validate configuration ------------------------------------
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
  DS_CLUSTER NETWORK VM_FOLDER DOMAIN_SUFFIX
  SSH_PUBLIC_KEY_1 K3S_TOKEN KUBE_API_HOSTNAME K3S_VERSION
)
for v in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "Missing required variable '${v}' in ${ENV_FILE}"
    exit 1
  fi
done
export GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_INSECURE
echo "All required variables present."

# --- Resolve the FCOS OVA (pinned local file, or download latest) ------
FCOS_STREAM="${FCOS_STREAM:-stable}"
if [[ -n "${FCOS_OVA:-}" ]]; then
  step "Using pinned FCOS OVA"
  if [[ ! -f "${FCOS_OVA}" ]]; then
    echo "FCOS_OVA is set to '${FCOS_OVA}' but that file does not exist."
    exit 1
  fi
  echo "Using: ${FCOS_OVA}"
else
  step "Resolving latest Fedora CoreOS OVA (stream: ${FCOS_STREAM})"
  OVA_DIR="${SCRIPT_DIR}/ova"
  mkdir -p "${OVA_DIR}"

  META_URL="https://builds.coreos.fedoraproject.org/streams/${FCOS_STREAM}.json"
  META=$(curl -sfL "${META_URL}")
  if [[ -z "${META}" ]]; then
    echo "Could not fetch FCOS stream metadata from ${META_URL}"
    exit 1
  fi

  OVA_URL=$(echo "${META}" | jq -r '.architectures.x86_64.artifacts.vmware.formats.ova.disk.location')
  OVA_SHA256=$(echo "${META}" | jq -r '.architectures.x86_64.artifacts.vmware.formats.ova.disk.sha256')

  if [[ -z "${OVA_URL}" || "${OVA_URL}" == "null" ]]; then
    echo "Could not find a VMware OVA artifact in stream '${FCOS_STREAM}' metadata."
    exit 1
  fi

  OVA_FILENAME=$(basename "${OVA_URL}")
  FCOS_OVA="${OVA_DIR}/${OVA_FILENAME}"

  NEED_DOWNLOAD=true
  if [[ -f "${FCOS_OVA}" ]]; then
    LOCAL_SHA256=$(sha256sum "${FCOS_OVA}" | awk '{print $1}')
    if [[ "${LOCAL_SHA256}" == "${OVA_SHA256}" ]]; then
      echo "Already up to date: ${FCOS_OVA}"
      NEED_DOWNLOAD=false
    else
      echo "Local copy is outdated or corrupt; re-downloading."
    fi
  fi

  if [[ "${NEED_DOWNLOAD}" == true ]]; then
    echo "Downloading ${OVA_URL}"
    curl -fL --progress-bar -o "${FCOS_OVA}.partial" "${OVA_URL}"

    DOWNLOADED_SHA256=$(sha256sum "${FCOS_OVA}.partial" | awk '{print $1}')
    if [[ "${DOWNLOADED_SHA256}" != "${OVA_SHA256}" ]]; then
      echo "Checksum mismatch after download!"
      echo "  expected: ${OVA_SHA256}"
      echo "  got:      ${DOWNLOADED_SHA256}"
      rm -f "${FCOS_OVA}.partial"
      exit 1
    fi

    mv "${FCOS_OVA}.partial" "${FCOS_OVA}"
    echo "Downloaded and verified: ${FCOS_OVA}"
  fi
fi

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

# --- Pick a datastore from the cluster with the most free space ---------
step "Selecting a datastore from cluster '${DS_CLUSTER}'"
DS_CLUSTER_PATH=$(govc find / -type StoragePod -name "${DS_CLUSTER}")
if [[ -z "${DS_CLUSTER_PATH}" ]]; then
  echo "No StoragePod (datastore cluster) named '${DS_CLUSTER}' found."
  echo "Available datastore clusters:"
  govc find / -type StoragePod
  exit 1
fi

# govc find -type Datastore -parent <StoragePod> does not reliably
# enumerate datastore cluster members; govc ls on the container does.
DATASTORES=$(govc ls "${DS_CLUSTER_PATH}")
if [[ -z "${DATASTORES}" ]]; then
  echo "StoragePod '${DS_CLUSTER_PATH}' returned no children via 'govc ls'."
  exit 1
fi

mapfile -t DS_ARRAY <<< "${DATASTORES}"
DS_JSON=$(govc datastore.info -json "${DS_ARRAY[@]}")
BEST_NAME=$(echo "${DS_JSON}" | jq -r '
    (.datastores // .Datastores)
    | max_by(.summary.freeSpace // .Summary.FreeSpace)
    | (.summary.name // .Summary.Name)
  ')

if [[ -z "${BEST_NAME}" || "${BEST_NAME}" == "null" ]]; then
  echo "Could not determine free space for any datastore under ${DS_CLUSTER}"
  exit 1
fi

DATASTORE=$(printf '%s\n' "${DS_ARRAY[@]}" | grep -F "/${BEST_NAME}")
echo "Selected datastore: ${DATASTORE} (from cluster ${DS_CLUSTER})"

# --- Build the import spec (thin disks, network mapping) ----------------
step "Building import spec (thin-provisioned disks, network mapped to '${NETWORK}')"
OPTIONS_FILE="${OUT_DIR}/${VM_NAME}-import-options.json"

# govc import.ova has no -network flag; network mapping is only
# available via -options with a NetworkMapping array.
govc import.spec "${FCOS_OVA}" \
  | jq --arg net "${NETWORK}" '
      .NetworkMapping = ((.NetworkMapping // []) | map(.Network = $net))
      | .DiskProvisioning = "thin"
      | .PowerOn = false
    ' > "${OPTIONS_FILE}"

if [[ "$(jq '.NetworkMapping | length' "${OPTIONS_FILE}")" -eq 0 ]]; then
  echo "Warning: OVF defines no networks to map; -options NetworkMapping will be empty."
  echo "The VM's NIC may need to be attached to '${NETWORK}' manually after import."
else
  echo "Import spec ready: ${OPTIONS_FILE}"
fi

# --- Import the OVA -------------------------------------------------------
step "Importing OVA as '${VM_NAME}' (this may take a few minutes)"
govc import.ova \
  -ds "${DATASTORE}" \
  -name "${VM_NAME}" \
  -options "${OPTIONS_FILE}" \
  -folder "${VM_FOLDER}" \
  "${FCOS_OVA}"
echo "Import complete."

# --- Resolve MAC address for a DHCP reservation --------------------------
step "Resolving VM MAC address for DHCP reservation"
VM_MAC=$(govc vm.info -json "${VM_NAME}" \
  | jq -r '.virtualMachines[0].config.hardware.device[] | select(.macAddress != null) | .macAddress' \
  | head -1)
echo "If you want a fixed IP for ${VM_NAME}, add a DHCP reservation for ${VM_MAC} now."

# --- Inject Ignition and power on -----------------------------------------
step "Injecting Ignition config and powering on"
govc vm.change -vm "${VM_NAME}" \
  -e "guestinfo.ignition.config.data.encoding=${CONFIG_ENCODING}" \
  -e "guestinfo.ignition.config.data=${CONFIG_ENCODED}"
govc vm.power -on "${VM_NAME}"
echo "Powered on."

echo ""
echo "Deployed ${VM_NAME}. It will join ${KUBE_API_HOSTNAME} once k3s server is reachable."
echo "Note: the node reboots itself once to finalize the open-vm-tools layer,"
echo "after k3s agent bootstrap has completed successfully."
