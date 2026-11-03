# 40b3 v3 — controlled OpenVox CA offline signing

Based on successful isolated-PKI test with OpenVox CA 3.3.0 on ca02. Production shared-PKI apply has **not** been tested.

Files:
- `40b3-openvox-ca-offline-sign.yml` — ca01/ca02 playbook
- `files/openvox-ca-offline-sign.rb` — signing and verification helper

Install into the Ansible repo, retaining `files/` directory. Review `git diff` before running.

## Safe initial execution

```bash
ansible-playbook -i ../generated/hosts.ini 40b3-openvox-ca-offline-sign.yml -e ca_sign_mode=check
```

`check` stages the CSR and helper under `/var/tmp` on ca01 but does not change the CA PKI. Ansible may report changed for staging.

## Before production apply

**Do not execute apply solely on the basis of the isolated test.** Validate these prerequisites:

1. Review all live CA writers and implement/verify external fencing (the playbook does not fence a failed or reachable remote VM). `ca_external_fencing_confirm=true` is an operator attestation, not an automated fence.
2. Confirm `ca01` and `ca02` are the only CA writers, and ensure no other clients/processes can write the shared PKI during maintenance. Verify NFS and host ownership, ensure no races.
3. Agree certificate TTL in seconds from actual deployment policy; do not blindly reuse the lab's five-year TTL.
4. Validate backups and rollback/partial-commit handling. Never automatically rewind serial after partial failure.
5. Review the `csr_attributes.yaml` choice: v3 uses `/srv/openvox-ca/csr_attributes.yaml` rather than host-local attributes. Confirm this is desired and that it is absent or safe.
6. Ensure `ca02` original private key is retained; test certificate created in `/var/lib/openvox-ca-sign-test` must NEVER be installed or copied into the production PKI.
7. The playbook leaves ca01 stopped and masked after apply (success or failure). Separate service restoration and certificate deployment procedures are required.

For planned maintenance only, after the above controls are independently verified, the playbook has gates for `ca_sign_mode=apply`, `ca_sign_approved=true`, `ca_sign_maintenance_confirm=true`, `ca_external_fencing_confirm=true`, and `ca_ttl_seconds=<seconds>`.

**Security:** the local pre-operation archive contains the CA private key. Restrict its access and retention. The staging CSR and helper do not contain the CA private key.

## Known limitations

- This is an offline signer, not a complete HA failover/fencing solution.
- `serial`, inventory, and signed cert are not updated atomically. A partial failure requires manual inspection before any retry/restart.
- Tests confirmed signing with a *local isolated PKI copy*, not safe concurrent use of the production NFS PKI.
- The code is specialized for `ca02.lab.example`, `DNS:puppet`, `DNS:ca02.lab.example`, and the lab NFS source; it is not a generic regional role.
- `check` cannot exercise `ca_ttl` or the signing path; isolated tests covered that path.
