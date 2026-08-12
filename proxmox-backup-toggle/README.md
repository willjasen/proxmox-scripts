# Proxmox backup toggle

Temporarily excludes one VM disk from daytime Proxmox backups, then includes it again before the nightly backup.

The default schedule is:

- 05:45: set the configured disk to `backup=0`
- 18:30: set the configured disk to `backup=1`

The schedule uses the Proxmox host's local time.

## Install

Copy this folder to the Proxmox host, then run:

```bash
sudo ./install.sh
```

If `.env` does not exist, the installer prompts for the VM ID, storage, and disk number, creates `.env`, and validates the values before installing. If `.env` already exists, it is validated without prompting.

The installer places the toggle script and configuration in `/usr/local/sbin/`, installs the systemd units, and enables both timers.

## Configuration

The configuration uses:

```env
VMID=2925
STORAGE=local-zfs
DISK_NUMBER=0
```

These values identify the volume as `local-zfs:vm-2925-disk-0`. The real `.env` is intentionally ignored by Git.

## Test manually

The installed script can be run directly:

```bash
sudo /usr/local/sbin/proxmox-backup-toggle exclude
sudo /usr/local/sbin/proxmox-backup-toggle include
```

For terminals that do not report color support correctly, force ANSI colors with:

```bash
sudo /usr/local/sbin/proxmox-backup-toggle --color=always exclude
```

Use `--color=never` to explicitly disable them.

Check the resulting VM configuration with:

```bash
qm config 2925
```

The script detects the disk device automatically (`scsi0`, `virtio0`, `sata0`, and so on) and preserves its other options.

## Check timers

```bash
systemctl list-timers 'proxmox-backup-toggle-*'
journalctl -u proxmox-backup-toggle-exclude.service
journalctl -u proxmox-backup-toggle-include.service
```

## Uninstall

From this folder, run:

```bash
sudo ./uninstall.sh
```

This disables the timers and removes the installed services, script, and installed configuration. The source `.env` in this folder is not removed.
