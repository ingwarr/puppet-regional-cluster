# OpenVox ca02 standby preparation v6

Copy `63-openvox-ca-standby.sh` to your repo `scripts/` directory; it sources your existing `scripts/lib/common.sh` and inventory (`CA02_NAME`, `NFS01_IP`, `CA_NFS_EXPORT`).

On ca02, while ca01 remains active:

```bash
bash -n scripts/63-openvox-ca-standby.sh
sudo ./scripts/63-openvox-ca-standby.sh inventory/lab01.env --check
sudo ./scripts/63-openvox-ca-standby.sh inventory/lab01.env --prepare
sudo ./scripts/63-openvox-ca-standby.sh inventory/lab01.env --validate
sudo systemctl is-active puppetserver || true
sudo systemctl is-enabled puppetserver || true
```

`--prepare` mounts the existing NFS CA state without starting OpenVox. It does NOT create a new CA or TLS host identity. The systemd `ExecStartPre` guard requires a root-owned, mode 0600 ephemeral `/run/openvox-ca/allow-start` file. The file is intentionally NEVER created by this script, and disappears on reboot. **Do not create it yet.** Its presence is a manual interlock, not fencing: a later failover procedure must positively fence/isolate ca01 before authorizing ca02 to start. No automated HA or failover is implemented here.

Root-squashed NFS CA files are inspected as `puppet`, not root. This script intentionally leaves `puppetserver` disabled. On an interrupted `--prepare`, do not rerun blindly: inspect the drop-in, fstab, mount, and service state. Test `--check` before `--prepare`. Do not use this script on ca01.

Next: provision ca02 host TLS certificate with `ca02.lab.example` and `puppet-ca.lab.example` SAN, signed by the existing ca01 CA; inspect the exact OpenVox signing workflow before running the service. Avoid copying ca01's host private key.
