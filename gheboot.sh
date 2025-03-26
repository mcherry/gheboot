#!/bin/bash -e
#/ GitHub Enterprise Server Boot
#/ Usage: gheboot [-vhbscmnd]
#/
#/ Creates and boots a new GitHub Enterprise Server appliance in Proxmox.
#/
#/ OPTIONS:
#/   -v  |  --version      Version of GHES to install
#/   -h  |  --hostname     Hostname for new virtual machine.
#/   -b  |  --bootstorage  Name of boot disk storage.
#/   -s  |  --ssdstorage   Name of SSD storage.
#/   -c  |  --cores        Number of vCPU cores. Default: 8
#/   -m  |  --memory       Amount of RAM in megabytes. Default: 65535
#/   -n  |  --network      Network device name. Default: vmbr0
#/   -d  |  --download     Download QCOW2 image for specified version.
#/
#/ EXAMPLE:
#/ 
#/ # Download GHES version 3.15.4, import it into "local" storage as "ghes-primary",
#/ # create a data drive on "local-ssd" storage, create a VM with 8 cores, 64GB ram,
#/ # and use the configured "vmbr0" network bridge
#/ 
#/ gheboot.sh -v 3.15.4 -h ghes-primary -b local -s local-ssd -c 8 -m 65535 -n vmbr0 -d

GHES_DOWNLOAD=0
CORES="8"
MEMORY="65535"
NETWORK="vmbr0"

function error() { echo "ERROR: $1"; exit 1; }
function show_help() { grep '^#/' < "$0" | cut -c4-; exit 1; }
if [ "$1" == "" ]; then show_help; fi

# process command line arguments
ARGUMENTS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--version)
      GHES_VERSION="$2"
      shift && shift
      ;;
    -h|--hostname)
      GHES_HOSTNAME="$2"
      shift && shift
      ;;
    -b|--bootstorage)
      BOOT_STORAGE="$2"
      shift && shift
      ;;
    -s|--ssdstorage)
      SSD_STORAGE="$2"
      shift && shift
      ;;
    -c|--cores)
      CORES="$2"
      shift && shift
      ;;
    -m|--memory)
      MEMORY="$2"
      shift && shift
      ;;
     -n|--network)
      NETWORK="$2"
      shift && shift
      ;;
    -d|--help)
      GHES_DOWNLOAD=1
      shift
      ;;
    -*|--*)
      show_help ;;
    *)
      ARGUMENTS+=("$1")
      shift
      ;;
  esac
done
set -- "${ARGUMENTS[@]}"

VM_ID=`pvesh get /cluster/nextid`
GHES_URL="https://github-enterprise.s3.amazonaws.com/kvm/releases/github-enterprise-$GHES_VERSION.qcow2"

if [ "$GHES_DOWNLOAD" == "1" ]; then
  wget "$GHES_URL" || error "Failed to download $GHES_URL"
fi

if [ -f "github-enterprise-$GHES_VERSION.qcow2" ]; then
  qm create $VM_ID \
    --name "$GHES_HOSTNAME" \
    --net0 virtio,bridge=$NETWORK \
    --ostype l26 \
    --memory $MEMORY \
    --onboot no \
    --cpu cputype=host \
    --sockets 1 \
    --cores $CORES \
    --vga qxl || error "Failed to create VM $GHES_HOSTNAME ($VM_ID)"

  qm importdisk $VM_ID "github-enterprise-$GHES_VERSION.qcow2" "$BOOT_STORAGE" || error "Failed to import root disk into appliance"
  qm set $VM_ID --scsi0 $BOOT_STORAGE:vm-$VM_ID-disk-0 || error "Failed to configure boot disk"
  qm set $VM_ID --boot order=scsi0 || error "Failed to set boot order"
  pvesm alloc "$SSD_STORAGE" "$VM_ID" vm-$VM_ID-disk-1 200G || error "Failed to allocate data storage disk"
  qm set $VM_ID --scsihw virtio-scsi-pci --scsi1 $SSD_STORAGE:vm-$VM_ID-disk-1,discard=on,ssd=1 || error "Failed to set data storage disk options"
  qm start $VM_ID || error "Failed to boot appliance"
else
  error "Disk image 'github-enterprise-$GHES_VERSION.qcow2' not found"
fi
