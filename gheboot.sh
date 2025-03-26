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

function print_help() { grep '^#/' < "$0" | cut -c4-; exit 1; }
function print_error() { echo "ERROR: $1"; exit 1; }
function run_command() { [ ! `command -v $1` ] && print_error "Command '$1' not found" || bash -c "$1 $2"; }
function download_image() { run_command "wget" "$1" || print_error "Failed to download $1"; }

function create_vm() {
  local vm_id=$1
  local ghes_version=$2
  local hostname=$3
  local boot_storage=$4
  local ssd_storage=$5
  local cores=$6
  local memory=$7
  local network=$8

  run_command "qm" "create $vm_id \
    --name '$hostname' \
    --net0 virtio,bridge=$network \
    --ostype l26 \
    --memory $memory \
    --onboot no \
    --cpu cputype=host \
    --sockets 1 \
    --cores $cores \
    --vga qxl" || print_error "Failed to create VM $hostname ($vm_id)"

  run_command "qm" "importdisk $vm_id 'github-enterprise-$ghes_version.qcow2' '$boot_storage'" || print_error "Failed to import root disk into appliance"
  run_command "qm" "set $vm_id --scsi0 $boot_storage:vm-$vm_id-disk-0" || print_error "Failed to configure boot disk"
  run_command "qm" "set $vm_id --boot order=scsi0" || error "Failed to set boot order"
  run_command "pvesm" "alloc '$ssd_storage' '$vm_id' vm-$vm_id-disk-1 200G" || print_error "Failed to allocate data storage disk"
  run_command "qm" "set $vm_id --scsihw virtio-scsi-pci --scsi1 $ssd_storage:vm-$vm_id-disk-1,discard=on,ssd=1" || print_error "Failed to set data storage disk options"
  run_command "qm" "start $vm_id" || print_error "Failed to boot appliance"
}

if [ "$1" == "" ]; then print_help; fi

# process command line arguments
ARGUMENTS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    -v|--version)
      GHES_VERSION="$2"
      shift 2
      ;;
    -h|--hostname)
      GHES_HOSTNAME="$2"
      shift 2
      ;;
    -b|--bootstorage)
      BOOT_STORAGE="$2"
      shift 2
      ;;
    -s|--ssdstorage)
      SSD_STORAGE="$2"
      shift 2
      ;;
    -c|--cores)
      CORES="$2"
      shift 2
      ;;
    -m|--memory)
      MEMORY="$2"
      shift 2
      ;;
     -n|--network)
      NETWORK="$2"
      shift 2
      ;;
    -d|--help)
      GHES_DOWNLOAD=1
      shift
      ;;
    -*|--*)
      print_help ;;
    *)
      ARGUMENTS+=("$1")
      shift
      ;;
  esac
done
set -- "${ARGUMENTS[@]}"

VM_ID=$(run_command "pvesh" "get /cluster/nextid")
GHES_URL="https://github-enterprise.s3.amazonaws.com/kvm/releases/github-enterprise-$GHES_VERSION.qcow2"

if [ "$GHES_DOWNLOAD" == "1" ]; then
  download_image "$GHES_URL"
fi

if [ -f "github-enterprise-$GHES_VERSION.qcow2" ]; then
  create_vm "$VM_ID" "$GHES_VERSION" "$GHES_HOSTNAME" "$BOOT_STORAGE" "$SSD_STORAGE" "$CORES" "$MEMORY" "$NETWORK"
else
  print_error "Disk image 'github-enterprise-$GHES_VERSION.qcow2' not found"
fi