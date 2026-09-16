# Proxmox host backups

Sets up automated Proxmox host configuration backups to Proxmox Backup Server using `proxmox-backup-client`.

This is for backing up the Proxmox host itself. VM and container disks should still be backed up by normal Proxmox/PBS backup jobs.

## Install

Copy this folder to a Proxmox host, then run:

```bash
sudo ./setup-host-backups.sh
```

The setup script detects the configured Proxmox PBS storage. If the default `PBS1` storage name is not present, it can use a matching storage such as `PBS1-lan`.

During setup it prompts for:

- PBS host or `host:port`
- PBS datastore
- PBS namespace
- PBS API token name
- PBS API token secret
- PBS certificate fingerprint, when needed
- backup schedule

Tailscale hostnames are fine for the PBS host, for example:

```text
pbs1.risk-mermaid.ts.net
```

## Installed files

The installer writes:

```text
/usr/local/sbin/proxmox-host-backup
/etc/proxmox-host-backup/env
/etc/proxmox-host-backup/pbs-credentials
/etc/proxmox-host-backup/include
/etc/proxmox-host-backup/exclude
/etc/systemd/system/proxmox-host-backup.service
/etc/systemd/system/proxmox-host-backup.timer
```

The credential file is mode `0600` and stores the generated `PBS_REPOSITORY` plus either `PBS_PASSWORD` or `PBS_PASSWORD_FILE`.

## Backup scope

By default the backup is intentionally narrow. It backs up host configuration and local admin files:

```text
/etc
/etc/pve
/root
/usr/local
/opt/proxmox-scripts
/var/spool/cron
```

It does not back up the full root filesystem. It also does not back up VM or CT storage.

The installed include list lives at:

```text
/etc/proxmox-host-backup/include
```

Each line has this format:

```text
archive-name:/path/to/back/up
```

## Schedule

The timer uses the Proxmox host's local time. The default schedule is `03:15`, and setup prompts before installing it.

Change the schedule later with:

```bash
sudo ./setup-host-backups.sh --schedule '03:15' --force
```

Check the timer with:

```bash
systemctl list-timers proxmox-host-backup.timer
```

## Manual backup

Run a backup manually with:

```bash
sudo /usr/local/sbin/proxmox-host-backup
```

Or through systemd:

```bash
sudo systemctl start proxmox-host-backup.service
sudo journalctl -u proxmox-host-backup.service -f
```

## Useful options

```bash
sudo ./setup-host-backups.sh \
  --pbs-host pbs1.risk-mermaid.ts.net \
  --datastore datastore1 \
  --namespace ns-1821/hosts \
  --api-token 'backups@pbs!pve-cluster' \
  --schedule 03:15
```

Use `--no-enable` to install files without enabling the timer.

Use `--force` to overwrite already-installed config, service, timer, include, and exclude files.
