# OpenVox CA NFS migration — v5

This revision supports retrying after an earlier failed migration when the NFS export already contains an exact copy of the local CA.

## Changes
- `--check` validates a populated NFS export using read-only `rsync --checksum --delete --dry-run` as the `puppet` account; it no longer requires an empty export.
- `--migrate` stops puppetserver and performs a final `rsync --checksum --delete` from the stopped local CA, then verifies the result before changing the live CA directory.
- Each migration attempt creates a new backup in `/root/openvox-ca-migration/attempt-*`; existing backups are preserved.
- Baseline CA identity is saved at `/etc/puppetlabs/puppetserver/ca-nfs-identity.sha256`, outside the mounted CA directory.
- Rollback retains NFS data and backups; it is a best-effort mechanism, not a substitute for an independent tested backup.

## Deployment
Copy `62-openvox-ca-storage.sh` into `scripts/` in the existing repository. The script depends on `scripts/lib/common.sh` and `inventory/lab01.env`.

Run on `ca01`:

```bash
bash -n scripts/62-openvox-ca-storage.sh
sudo ./scripts/62-openvox-ca-storage.sh inventory/lab01.env --check
```

Before migration: confirm `ca02` is stopped, independent CA backup exists, and maintenance window is approved. Then:

```bash
sudo ./scripts/62-openvox-ca-storage.sh inventory/lab01.env --migrate
sudo ./scripts/62-openvox-ca-storage.sh inventory/lab01.env --validate
sudo ./scripts/61-openvox-ca-validate.sh inventory/lab01.env
```

## Safety caveats
- Do not run both CA instances simultaneously. NFS file locking is not fencing.
- `--check` may report differences if the active CA changes after the prior NFS snapshot; this is intentional. Inspect the differences, then only proceed with `--migrate` after confirming the NFS export contains no independent state.
- `--migrate` performs `rsync --delete` on the NFS destination. Use only if the NFS export is a replica of this CA and has no independent state.
- The systemd guard verifies the mount at service startup, but it does not replace host fencing or robust failover orchestration.
- `63-openvox-ca-standby.sh` is copied unchanged from v4 and should not be run until migration is fully validated.
