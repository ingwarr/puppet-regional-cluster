# OpenVox CA NFS migration v4 — diagnostic candidate

Fixes the `root_squash` failure by reading CA private material as the `puppet` service user (UID 52). CA certificate/key public-key identities are compared before switching and after mounting. NFS copy is checked using rsync checksum dry run, including unexpected extra files.

**Do not run --migrate yet.** The failed v3 attempt may have left `/root/openvox-ca-migration`, a partially populated NFS export, and other rollback artifacts. The v4 script intentionally refuses to overwrite an existing backup directory. Inspect these before a new migration; never delete backups or CA files automatically.

1. On ca01: `bash -n scripts/62-openvox-ca-storage.sh`
2. Run `sudo ./scripts/61-openvox-ca-validate.sh inventory/lab01.env`.
3. Run `sudo ./scripts/62-openvox-ca-storage.sh inventory/lab01.env --check`.
4. Inspect `sudo ls -la /root/openvox-ca-migration` and `sudo -u puppet find /mnt/openvox-ca-test -mindepth 1 -maxdepth 2 -printf '%P\n'`.
5. Check any leftover fstab entries/drop-ins before scheduling migration.

`63-openvox-ca-standby.sh` is carried over from v3, not yet validated for this new design; do not execute it.

Note: `ca_identity` computes the SHA256 of the DER-encoded public key extracted independently from the CA certificate and private key. This is *not* the certificate fingerprint; it is an identity consistency check.
