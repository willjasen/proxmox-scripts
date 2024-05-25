#!/bin/bash

# Static variables
SSH_PUB_FILE=~/.ssh/willjasen.pub;
IPFS_GATEWAY=https://ipfs.io/ipfs;
IMAGE_IPFS_HASH=QmXoZm3ee4eHvFZ8FPPs8BTyHGC3cLEzXPxuEgUUDNkkgj;
PUBKEY_IPFS_HASH=QmSkVe4aH9KCoBCXgNKYjpX1Kd9QrT19Q5DohApkqURHmk;
IMAGE_FILENAME=ubuntu-24.04-minimal-cloudimg-amd64.img;
VM_DATASTORE=zfs;

# Varied variables
random_number=$(( RANDOM % 1000 ));
formatted_number=$(printf "%03d" $random_number);
VM_ID="9$formatted_number";

# Create symbolic link for userconfig.yaml if needed
if [ ! -L /var/lib/vz/snippets/userconfig.yaml ]; then
  ln -s $PWD/userconfig.yaml /var/lib/vz/snippets/userconfig.yaml;
fi;

# Download the image if needed
if [ ! -f $PWD/$IMAGE_FILENAME ]; then
  wget -O $IMAGE_FILENAME $IPFS_GATEWAY/$IMAGE_IPFS_HASH;
fi;

# Add the SSH public key
# if [ ! -f $SSH_PUB_FILE \; then
  ## The public key can be created via retrieving a DNS TXT record (preferably with the domain protected by DNSSEC)
#   dig TXT ssh.willjasen.com +short | sed -e 's/" "//g' -e 's/"//g' > $SSH_PUB_FILE;

  ## The public key can be retrieved from IPFS
  # curl $IPFS_GATEWAY/$PUBKEY_IPFS_HASH > $SSH_PUB_FILE;
# fi;

qm create $VM_ID --memory 2048 --net0 virtio,bridge=vmbr0,tag=123 --scsihw virtio-scsi-pci;
qm set $VM_ID --scsi0 $VM_DATASTORE:0,import-from=$PWD/$IMAGE_FILENAME;
qm set $VM_ID --ide2 $VM_DATASTORE:cloudinit;
qm set $VM_ID --boot order=scsi0;
qm set $VM_ID --serial0 socket --vga serial0;
qm set $VM_ID --ipconfig0 ip=dhcp;
qm set $VM_ID --nameserver "1.1.1.1";
qm set $VM_ID --agent enabled=1;
qm set $VM_ID --cicustom "user=local:snippets/userconfig.yaml"
qm start $VM_ID;
