# Patroni for lab01 (AlmaLinux 9, PostgreSQL 16, etcd 3.7)

Merge the contents of this archive into `openvox-kvm-lab/ansible/` (not into the project root). Requires existing `postgresql` inventory group, `ansible_host` for pg01/pg02/pg03, the completed PostgreSQL role and a healthy etcd cluster.

## Passwords

Create `group_vars/postgresql-vault.yml` with `ansible-vault create group_vars/postgresql-vault.yml`:

```yaml
patroni_superuser_password: 'YOUR_SECRET'
patroni_replication_password: 'YOUR_OTHER_SECRET'
```

Add `vars_files: [group_vars/postgresql-vault.yml]` to the first play in `21-patroni.yml`, **or** provide the vault file with `-e @group_vars/postgresql-vault.yml` at invocation. The latter is shown below. Never commit the plaintext file.

## Preflight

Run on a fresh lab only. Verify no `PG_VERSION` exists under `/var/lib/pgsql/16/data` and no prior Patroni DCS state exists in etcd under `/service/lab01-postgresql/`. Do not wipe existing data to satisfy this precondition; stop and investigate if state already exists.

```bash
cd openvox-kvm-lab/ansible
ansible-playbook -i ../generated/hosts.ini 21-patroni.yml --syntax-check
ansible-playbook -i ../generated/hosts.ini 21-patroni.yml --ask-vault-pass -e @group_vars/postgresql-vault.yml
```

`serial: 1` starts pg01 first, then pg02, then pg03. Patroni handles initialization and replicas. Validation checks 3 running members and 1 leader. Repeat playbook to check idempotence. Package versions are not pinned in this lab iteration; pin tested versions before production.

**Caution:** changing the template on a running Patroni instance deliberately fails instead of automatically restarting the database. Bootstrap-only settings in `bootstrap.dcs` do not update existing DCS configuration after first initialization. For existing clusters use `patronictl edit-config` and a controlled rolling restart where necessary.

The systemd unit mirrors the old Bash script's local-etcd dependency. This is suitable for the lab where every PostgreSQL node also hosts etcd, not necessarily for production separation.
