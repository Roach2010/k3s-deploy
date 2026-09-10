#!/bin/bash
# Shared functions for the FCOS/k3s govc deploy scripts.
# This file is meant to be sourced, not executed directly.

STEP=0
TOTAL_STEPS="${TOTAL_STEPS:-8}"

step() {
  STEP=$((STEP + 1))
  echo ""
  echo "==> [${STEP}/${TOTAL_STEPS}] $1"
}

# Sets VM_NAME, WAIT_FOR_RESERVATION, CLUSTER_INIT, and JOIN_CLUSTER from
# the calling script's "$@". Recognizes --wait-for-reservation/-w,
# --cluster-init/-c, and --join/-j in any order/combination; it's up to
# the calling script to reject flags that don't apply to its role (e.g.
# worker scripts should reject --cluster-init and --join).
parse_args() {
  if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <hostname> [--wait-for-reservation|-w] [--cluster-init|-c] [--join|-j]"
    exit 1
  fi
  VM_NAME=$1
  shift

  WAIT_FOR_RESERVATION=false
  CLUSTER_INIT=false
  JOIN_CLUSTER=false
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
      *)
        echo "Unknown argument: $1"
        echo "Usage: $0 <hostname> [--wait-for-reservation|-w] [--cluster-init|-c] [--join|-j]"
        exit 1
        ;;
    esac
    shift
  done
}

# load_env <env_file>
load_env() {
  local env_file="$1"
  step "Loading configuration from ${env_file}"
  if [[ ! -f "${env_file}" ]]; then
    echo "Missing ${env_file}"
    echo "Copy deploy.env.example to deploy.env and fill in real values first."
    exit 1
  fi
  # shellcheck disable=SC1090
  source "${env_file}"
  echo "Loaded."
}

# validate_vars <var_name> [<var_name> ...]
validate_vars() {
  step "Validating required variables"
  local v
  for v in "$@"; do
    if [[ -z "${!v:-}" ]]; then
      echo "Missing required variable '${v}' in ${ENV_FILE}"
      exit 1
    fi
  done
  export GOVC_URL GOVC_USERNAME GOVC_PASSWORD GOVC_INSECURE
  echo "All required variables present."
}

# render_ignition <template_bu_path> <out_dir> <vm_name> <sed args...>
# Sets CONFIG_ENCODING and CONFIG_ENCODED.
render_ignition() {
  local template="$1" out_dir="$2" vm_name="$3"
  shift 3
  step "Rendering Butane template and compiling to Ignition"

  sed "$@" "${template}" > "${out_dir}/${vm_name}.bu"
  butane --pretty --strict "${out_dir}/${vm_name}.bu" > "${out_dir}/${vm_name}.ign"

  CONFIG_ENCODING=base64
  CONFIG_ENCODED=$(base64 -w0 "${out_dir}/${vm_name}.ign")
  echo "Ignition config ready: ${out_dir}/${vm_name}.ign"
}

# select_datastore <ds_cluster_name>
# Sets DATASTORE to the full inventory path of the member with the most
# free space. Resolves all members in a single govc datastore.info call
# instead of one call per datastore.
select_datastore() {
  local ds_cluster="$1"
  step "Selecting a datastore from cluster '${ds_cluster}'"

  local ds_cluster_path
  ds_cluster_path=$(govc find / -type StoragePod -name "${ds_cluster}")
  if [[ -z "${ds_cluster_path}" ]]; then
    echo "No StoragePod (datastore cluster) named '${ds_cluster}' found."
    echo "Available datastore clusters:"
    govc find / -type StoragePod
    exit 1
  fi

  # govc find -type Datastore -parent <StoragePod> does not reliably
  # enumerate datastore cluster members; govc ls on the container does.
  local datastores
  datastores=$(govc ls "${ds_cluster_path}")
  if [[ -z "${datastores}" ]]; then
    echo "StoragePod '${ds_cluster_path}' returned no children via 'govc ls'."
    exit 1
  fi

  local ds_array
  mapfile -t ds_array <<< "${datastores}"

  local ds_json best_name
  ds_json=$(govc datastore.info -json "${ds_array[@]}")
  best_name=$(echo "${ds_json}" | jq -r '
      (.datastores // .Datastores)
      | max_by(.summary.freeSpace // .Summary.FreeSpace)
      | (.summary.name // .Summary.Name)
    ')

  if [[ -z "${best_name}" || "${best_name}" == "null" ]]; then
    echo "Could not determine free space for any datastore under ${ds_cluster}"
    exit 1
  fi

  DATASTORE=$(printf '%s\n' "${ds_array[@]}" | grep -F "/${best_name}")
  echo "Selected datastore: ${DATASTORE} (from cluster ${ds_cluster})"
}

# build_import_options <fcos_ova> <network> <out_file>
# Sets OPTIONS_FILE.
build_import_options() {
  local fcos_ova="$1" network="$2" out_file="$3"
  step "Building import spec (thin-provisioned disks, network mapped to '${network}')"

  # govc import.ova has no -network flag; network mapping is only
  # available via -options with a NetworkMapping array.
  govc import.spec "${fcos_ova}" \
    | jq --arg net "${network}" '
        .NetworkMapping = ((.NetworkMapping // []) | map(.Network = $net))
        | .DiskProvisioning = "thin"
        | .PowerOn = false
      ' > "${out_file}"

  if [[ "$(jq '.NetworkMapping | length' "${out_file}")" -eq 0 ]]; then
    echo "Warning: OVF defines no networks to map; -options NetworkMapping will be empty."
    echo "The VM's NIC may need to be attached to '${network}' manually after import."
  else
    echo "Import spec ready: ${out_file}"
  fi
  OPTIONS_FILE="${out_file}"
}

# ensure_fcos_ova <stream> <ova_dir>
# If FCOS_OVA is already set (pinned to a local file), verifies it exists
# and uses it as-is. Otherwise downloads the latest OVA for <stream> from
# the Fedora CoreOS build metadata, verifying its sha256 checksum, and
# skips re-downloading if the current local copy already matches.
# Sets/leaves FCOS_OVA pointing at the local file to use.
ensure_fcos_ova() {
  local stream="$1" ova_dir="$2"

  if [[ -n "${FCOS_OVA:-}" ]]; then
    step "Using pinned FCOS OVA"
    if [[ ! -f "${FCOS_OVA}" ]]; then
      echo "FCOS_OVA is set to '${FCOS_OVA}' but that file does not exist."
      exit 1
    fi
    echo "Using: ${FCOS_OVA}"
    return 0
  fi

  step "Resolving latest Fedora CoreOS OVA (stream: ${stream})"
  mkdir -p "${ova_dir}"

  local meta_url="https://builds.coreos.fedoraproject.org/streams/${stream}.json"
  local meta
  meta=$(curl -sfL "${meta_url}")
  if [[ -z "${meta}" ]]; then
    echo "Could not fetch FCOS stream metadata from ${meta_url}"
    exit 1
  fi

  local ova_url ova_sha256
  ova_url=$(echo "${meta}" | jq -r '.architectures.x86_64.artifacts.vmware.formats.ova.disk.location')
  ova_sha256=$(echo "${meta}" | jq -r '.architectures.x86_64.artifacts.vmware.formats.ova.disk.sha256')

  if [[ -z "${ova_url}" || "${ova_url}" == "null" ]]; then
    echo "Could not find a VMware OVA artifact in stream '${stream}' metadata."
    exit 1
  fi

  local ova_filename
  ova_filename=$(basename "${ova_url}")
  FCOS_OVA="${ova_dir}/${ova_filename}"

  if [[ -f "${FCOS_OVA}" ]]; then
    local local_sha256
    local_sha256=$(sha256sum "${FCOS_OVA}" | awk '{print $1}')
    if [[ "${local_sha256}" == "${ova_sha256}" ]]; then
      echo "Already up to date: ${FCOS_OVA}"
      return 0
    fi
    echo "Local copy is outdated or corrupt; re-downloading."
  fi

  echo "Downloading ${ova_url}"
  curl -fL --progress-bar -o "${FCOS_OVA}.partial" "${ova_url}"

  local downloaded_sha256
  downloaded_sha256=$(sha256sum "${FCOS_OVA}.partial" | awk '{print $1}')
  if [[ "${downloaded_sha256}" != "${ova_sha256}" ]]; then
    echo "Checksum mismatch after download!"
    echo "  expected: ${ova_sha256}"
    echo "  got:      ${downloaded_sha256}"
    rm -f "${FCOS_OVA}.partial"
    exit 1
  fi

  mv "${FCOS_OVA}.partial" "${FCOS_OVA}"
  echo "Downloaded and verified: ${FCOS_OVA}"
}

# build_tls_san_flags <comma-separated-list>
# Echoes "--tls-san=val1 --tls-san=val2 ..." for each non-empty, trimmed
# value in the comma-separated list. Lets a single deploy.env value hold
# an IP and an FQDN (or more) together, e.g. "192.168.60.10,k3s.roach.lan".
build_tls_san_flags() {
  local csv="$1" flags="" val
  IFS=',' read -ra vals <<< "${csv}"
  for val in "${vals[@]}"; do
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    [[ -n "${val}" ]] && flags+="--tls-san=${val} "
  done
  printf '%s' "${flags}"
}

# import_vm <datastore> <vm_name> <options_file> <fcos_ova> <folder>
import_vm() {
  local datastore="$1" vm_name="$2" options_file="$3" fcos_ova="$4" folder="$5"
  step "Importing OVA as '${vm_name}' (this may take a few minutes)"
  govc import.ova \
    -ds "${datastore}" \
    -name "${vm_name}" \
    -options "${options_file}" \
    -folder "${folder}" \
    "${fcos_ova}"
  echo "Import complete."
}

# resolve_mac <vm_name>
# Sets VM_MAC.
resolve_mac() {
  local vm_name="$1"
  step "Resolving VM MAC address for DHCP reservation"
  VM_MAC=$(govc vm.info -json "${vm_name}" \
    | jq -r '.virtualMachines[0].config.hardware.device[] | select(.macAddress != null) | .macAddress' \
    | head -1)
  echo "VM MAC address: ${VM_MAC}"
}

maybe_wait_for_reservation() {
  if [[ "${WAIT_FOR_RESERVATION}" == true ]]; then
    read -r -p "Press Enter once the DHCP reservation has been added to continue with power-on... "
  fi
}

# inject_and_power_on <vm_name> <config_encoding> <config_encoded>
inject_and_power_on() {
  local vm_name="$1" config_encoding="$2" config_encoded="$3"
  step "Injecting Ignition config and powering on"
  govc vm.change -vm "${vm_name}" \
    -e "guestinfo.ignition.config.data.encoding=${config_encoding}" \
    -e "guestinfo.ignition.config.data=${config_encoded}"
  govc vm.power -on "${vm_name}"
  echo "Powered on."
}
