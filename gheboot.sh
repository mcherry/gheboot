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
#/   -o  |  --onboot       Configure VM to boot when hypervisor reboots.
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
ONBOOT="no"

function print_help() { grep '^#/' < "$0" | cut -c4-; exit 1; }
function print_error() { echo "ERROR: $1"; exit 1; }
function run_command() { [ ! `command -v $1` ] && print_error "Command '$1' not found" || bash -c "$1 $2"; }
function download_image() { run_command "wget" "$1" || print_error "Failed to download $1"; }

function create_vm() {
  declare -n ghes_vm=$1
  
  run_command "qm" "create ${ghes_vm[id]} \
    --name '${ghes_vm[hostname]}' \
    --net0 virtio,bridge=${ghes_vm[network]} \
    --ostype l26 \
    --memory ${ghes_vm[memory]} \
    --onboot $ghes_vm[onboot] \
    --cpu cputype=host \
    --sockets 1 \
    --cores ${ghes_vm[cores]} \
    --vga qxl" || print_error "Failed to create '${ghes_vm[hostname]}' (${ghes_vm[id]})"

  run_command "qm" "importdisk ${ghes_vm[id]} 'github-enterprise-${ghes_vm[version]}.qcow2' '${ghes_vm[boot_storage]}'" || print_error "Failed to import root disk"
  run_command "qm" "set ${ghes_vm[id]} --scsi0 ${ghes_vm[boot_storage]}:vm-${ghes_vm[id]}-disk-0" || print_error "Failed to configure boot disk"
  run_command "qm" "set ${ghes_vm[id]} --boot order=scsi0" || error "Failed to configure boot order"
  run_command "pvesm" "alloc '${ghes_vm[ssd_storage]}' '${ghes_vm[id]}' vm-${ghes_vm[id]}-disk-1 200G" || print_error "Failed to allocate storage disk"
  run_command "qm" "set ${ghes_vm[id]} --scsihw virtio-scsi-pci --scsi1 ${ghes_vm[ssd_storage]}:vm-${ghes_vm[id]}-disk-1,discard=on,ssd=1" || print_error "Failed to configure storage disk"
  run_command "qm" "start ${ghes_vm[id]}" || print_error "Failed to boot"
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
    -o|--onboot)
      ONBOOT="yes"
      shift
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
  declare -A new_vm=(
    [id]="$VM_ID"
    [version]="$GHES_VERSION"
    [hostname]="$GHES_HOSTNAME"
    [boot_storage]="$BOOT_STORAGE"
    [ssd_storage]="$SSD_STORAGE"
    [cores]="$CORES"
    [memory]="$MEMORY"
    [network]="$NETWORK"
    [onboot]="$ONBOOT"
  )
  create_vm new_vm
else
  print_error "Disk image 'github-enterprise-$GHES_VERSION.qcow2' not found"
fi