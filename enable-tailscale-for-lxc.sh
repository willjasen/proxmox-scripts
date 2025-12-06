#!/bin/bash
# filepath: ./enable-tailscale-for-lxc.sh

LXC_ID=1818;

sed -i '$a lxc.cgroup2.devices.allow: c 10:200 rwm' /etc/pve/lxc/$LXC_ID.conf
sed -i '$a lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' /etc/pve/lxc/$LXC_ID.conf