# Maintenance notes

- Keep the real `.env` out of Git. Use `.env.example` for documented defaults only.
- The script must remain safe to run repeatedly with either `exclude` or `include`.
- Preserve existing disk options when changing the `backup` flag.
- Keep the install and uninstall paths aligned with the systemd unit `ExecStart` paths.
- Validate shell scripts with `bash -n` after changes.
- Test systemd unit syntax on a Proxmox host with `systemd-analyze verify` before deployment.
- Do not run the installer from a non-Proxmox machine; it requires root, `qm`, and systemd.
