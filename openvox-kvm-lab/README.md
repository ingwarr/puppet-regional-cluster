# OpenVox KVM lab bootstrap

Creates nine libvirt domains using qcow2 backing overlays from an **offline, generalized, cloud-init-enabled** AlmaLinux 9 base image. Generates Ansible inventory and an `/etc/hosts` fragment. By default VMs are **defined but not started**.

## Prerequisites

- KVM/libvirt and active `default` NAT network `192.168.122.0/24` (gateway `192.168.122.1`).
- `virt-install`, `qemu-img`, `cloud-localds` (typically `cloud-utils`), `virsh`, Python 3.
- Base image with `cloud-init` installed/enabled, `NetworkManager`, and no fixed machine-id, SSH host keys or inherited cloud-init instance state. **Do not use a running VM disk as the template**. Power down the template and generalize it safely first. Keep the template unchanged for the life of its overlays.
- SSH public key (defaults to invoking user's `~/.ssh/id_ed25519.pub` for a typical `/home/$SUDO_USER`).

## Example

```bash
sudo TEMPLATE=/var/lib/libvirt/images/alma9-template.qcow2 \
  SSH_PUBKEY=/home/YOUR_USER/.ssh/id_ed25519.pub \
  ./create-lab.sh

cat generated/hosts.ini
cat generated/hosts.fragment

# Start selected VMs after reviewing the definitions
sudo virsh start pg01
```

Override `NETWORK`, `DOMAIN`, `IMAGE_DIR`, `OUTPUT_DIR`, `GATEWAY`, `PREFIX`, `DNS`, `TOPOLOGY`, and `START=1` if needed. If libvirt NAT uses DHCP, reserve these static IPs outside the DHCP pool to prevent conflicts. The generated hosts fragment is NOT automatically written to the host's `/etc/hosts`.

**Warning:** The template must process cloud-init NoCloud seed and network-config on first boot. Test with one VM before starting all nine. `--print-xml` and `virsh define` avoid starting VMs during provisioning. If provisioning fails midway, inspect partial disk/seed/domain before retrying. The script never deletes existing disks.

Memory allocation: 25 GiB nominal guest RAM, excluding host and transient overhead. CPU is oversubscribed; start in phases for a T480.
