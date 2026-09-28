# Synology CSI

This role installs Synology CSI `v1.4.0` and an iSCSI `StorageClass` for a
Synology NAS with SAN Manager. It is intended for the K3s cluster bootstrap.

The role creates one `client-info-secret` from the DSM credentials, applies the
pinned upstream controller and node manifests, and waits for both workloads.
The DSM password must be supplied through Ansible Vault. The default class is
`synology-iscsi-storage`, uses `/volume1`, keeps volumes with `Retain`, and is
not the cluster default.

The FCOS nodes must have `iscsi-init.service` and `iscsid.service` enabled. FCOS already includes the
`iscsi-initiator-utils` tools used by the driver; no NFS package or host NFS
mount is needed for this CSI driver.

Configure the inventory values and vault keys before running:

```yaml
synology_csi_dsm_host: <nas-ip>
synology_csi_dsm_username: synology-csi
synology_csi_dsm_password: !vault |
  ...
synology_csi_storage_location: /volume1
```

The DSM user should be dedicated, in the administrators group, and allowed to
access DSM. Create the LUNs through Kubernetes PVCs; do not pre-create a LUN
for each claim. Test with a small PVC and pod before putting application data
on the class. `Retain` preserves the DSM volume when a claim is removed.

The CSI driver does not implement controller-side publish/unpublish. The role
therefore registers it with `attachRequired: false`; this avoids an external
attacher call the driver cannot satisfy. A powered-off or fenced failed node
must be confirmed clear of its iSCSI session before forcing a workload onto
another node.
