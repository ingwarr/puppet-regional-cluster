# OpenVox CA NFS scripts v3 (lab)

Run on ca01 after off-host encrypted backup, maintenance window, and a successful `--check`:

```bash
sudo ./scripts/62-openvox-ca-storage.sh inventory/lab01.env --check
sudo ./scripts/62-openvox-ca-storage.sh inventory/lab01.env --migrate
sudo ./scripts/62-openvox-ca-storage.sh inventory/lab01.env --validate
sudo ./scripts/61-openvox-ca-validate.sh inventory/lab01.env
```

Version 3 adds an EXIT-trap rollback to `62 --migrate`. On a migration failure, it attempts to unmount CA NFS, restore the original local CA directory, remove the script's mount/guard settings, and restart the original service. If NFS cannot be unmounted or local CA state cannot be restored, it leaves the service stopped for manual recovery. The NFS copy and backup are retained. **This is not a fully transactional rollback and has not been tested on your VMs.** Never rerun `--migrate` blindly after a failure.

Before migration, confirm no issuance/revocation is in progress and copy a protected backup **off the CA VM**. `ca02` must stay inactive. NFS is still a single point of failure in the lab. `63` is unchanged from v2 and is not a failover mechanism. Verify the `puppetserver` systemd drop-in after migration. Do not start `ca02` until a fencing procedure and its separate TLS host identity are ready.
