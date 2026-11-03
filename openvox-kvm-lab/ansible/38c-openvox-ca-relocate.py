#!/usr/bin/env python3
"""Conservative, single-host OpenVox CA relocation helper. Never deletes sources."""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import stat
import sys

SOURCE_CA = Path('/opt/puppetlabs/server/data/puppetserver/.puppetlabs/etc/puppetserver/ca')
SOURCE_SSL = Path('/opt/puppetlabs/server/data/puppetserver/.puppetlabs/etc/puppet/ssl')
TARGET_CA = Path('/srv/openvox-ca')
TARGET_SSL = Path('/etc/puppetlabs/puppet/ssl')
REQUIRED_CA = ['ca_crt.pem','ca_key.pem','ca_pub.pem','root_key.pem','ca_crl.pem','infra_crl.pem','serial','inventory.txt','infra_inventory.txt','infra_serials','signed/ca01.lab.example.pem']
REQUIRED_SSL = ['certs/ca01.lab.example.pem','certs/ca.pem','private_keys/ca01.lab.example.pem','public_keys/ca01.lab.example.pem','crl.pem']

def fail(message):
    raise RuntimeError(message)

def contents(path):
    return list(path.iterdir()) if path.is_dir() else []

def validate_source(path, required):
    if not path.is_dir() or path.is_symlink():
        fail(f'Invalid source directory: {path}')
    for item in required:
        p = path / item
        if not p.is_file() or p.is_symlink():
            fail(f'Missing/unsafe source file: {p}')

def inventory(root):
    result = {}
    def walk(folder, prefix=''):
        for child in sorted(folder.iterdir()):
            rel = prefix + child.name
            info = child.lstat()
            if stat.S_ISLNK(info.st_mode):
                result[rel] = ('link', os.readlink(child))
            elif stat.S_ISDIR(info.st_mode):
                result[rel] = ('dir', stat.S_IMODE(info.st_mode))
                walk(child, rel + '/')
            elif stat.S_ISREG(info.st_mode):
                h = hashlib.sha256()
                with child.open('rb') as stream:
                    for block in iter(lambda: stream.read(1024*1024), b''):
                        h.update(block)
                result[rel] = ('file', h.hexdigest(), stat.S_IMODE(info.st_mode))
            else:
                fail(f'Unsupported file type: {child}')
    walk(root)
    return result

def copy_contents(source, target):
    # Run as puppet. Copy each top-level item, keeping metadata and symlinks.
    for entry in sorted(source.iterdir()):
        destination = target / entry.name
        if destination.exists() or destination.is_symlink():
            fail(f'Destination collision: {destination}')
        if entry.is_symlink():
            destination.symlink_to(os.readlink(entry))
        elif entry.is_dir():
            shutil.copytree(entry, destination, symlinks=True, copy_function=shutil.copy2)
        elif entry.is_file():
            shutil.copy2(entry, destination, follow_symlinks=False)
        else:
            fail(f'Unsupported source: {entry}')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--mode', choices=['preflight','copy','verify'], required=True)
    parser.add_argument('--confirm', action='store_true')
    args = parser.parse_args()
    validate_source(SOURCE_CA, REQUIRED_CA)
    validate_source(SOURCE_SSL, REQUIRED_SSL)
    if not TARGET_CA.is_dir() or TARGET_CA.is_symlink():
        fail('NFS target is not a real directory')
    if not os.path.ismount(TARGET_CA):
        fail('NFS target is not a mountpoint')
    if not TARGET_SSL.is_dir() or TARGET_SSL.is_symlink():
        fail('SSL target is not a real directory')
    src_ca = inventory(SOURCE_CA)
    src_ssl = inventory(SOURCE_SSL)
    ca_empty = not contents(TARGET_CA)
    ssl_empty = not contents(TARGET_SSL)
    if args.mode == 'preflight':
        if not (ca_empty and ssl_empty):
            # A complete, verified relocation is an allowed no-op; partial state fails.
            if inventory(TARGET_CA) != src_ca or inventory(TARGET_SSL) != src_ssl:
                fail('Non-empty destination differs from source; refusing partial relocation')
            print('ALREADY_COPIED_AND_VERIFIED')
        else:
            print('READY_EMPTY_TARGETS')
        return
    if args.mode == 'copy':
        if not args.confirm:
            fail('Explicit --confirm required')
        if not (ca_empty and ssl_empty):
            if inventory(TARGET_CA) == src_ca and inventory(TARGET_SSL) == src_ssl:
                print('ALREADY_COPIED_AND_VERIFIED')
                return
            fail('Destination not empty; refusing to copy')
        copy_contents(SOURCE_CA, TARGET_CA)
        copy_contents(SOURCE_SSL, TARGET_SSL)
    if inventory(TARGET_CA) != src_ca:
        fail('CA copy verification mismatch')
    if inventory(TARGET_SSL) != src_ssl:
        fail('SSL copy verification mismatch')
    print('COPY_VERIFIED')

if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
