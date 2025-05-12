#!/bin/bash -e
#/ GitHub Enterprise Server Boot
#/ Usage: gheboot [-vhbsucmnrlpodk]
#/
#/ Creates and boots a new GitHub Enterprise Server appliance in Proxmox.
#/
#/ OPTIONS:
#/   -v  |  --version      Version of GHES to install
#/   -h  |  --hostname     Hostname for new virtual machine.
#/   -b  |  --bootstorage  Name of boot disk storage.
#/   -s  |  --ssdstorage   Name of SSD storage.
#/   -u  |  --userdatasize Size of the data disk in GB. Default: 200
#/   -c  |  --cores        Number of vCPU cores. Default: 8
#/   -t  |  --cputype      CPU type. Default: host
#/   -m  |  --memory       Amount of RAM in megabytes. Default: 65535
#/   -n  |  --network      Network device name. Default: vmbr0
#/   -r  |  --root         Root site password for initial configuration.
#/   -l  |  --license      Path to license file.
#/   -i  |  --ipnetmask    IP network that the VM will be on. This is necessary
#/                         for the initial configuration to work and should be
#/                         in CIDR format. Example: 192.168.1.0/24
#/   -p  |  --poweron      Power on VM after creation.
#/   -o  |  --onboot       Configure VM to boot when hypervisor reboots.
#/   -d  |  --download     Download QCOW2 image for specified version.
#/   -k  |  --insecure     Allow insecure HTTPS connection for initial configuration.
#/
#/ EXAMPLE:
#/
#/ # Download GHES version 3.16.1, import it into "local" storage as "ghes-primary",
#/ # create a data drive on "local-ssd" storage, create a VM with 8 cores, 64GB ram,
#/ # and use the configured "vmbr0" network bridge. Also configure root site password and
#/ # upload license.
#/
#/ gheboot.sh -v 3.16.1 -h ghes-primary -b local -s local-ssd -c 8 -m 65535 -n vmbr0 \
#/     -r "YourPassword123@" -l license-file.ghl -i 192.168.1.0/24 -k -p -d

GHES_DOWNLOAD=0
CORES="8"
MEMORY="65535"
NETWORK="vmbr0"
ONBOOT="no"
POWERON=0
ALLOW_INSECURE=""
IP_NETMASK=""
CPUTYPE="host"
USERDATAGB="200"

function print_help() { grep '^#/' < "$0" | cut -c4-; exit 1; }
function print_error() { echo "ERROR: $1"; exit 1; }
function run_command() { [ ! `command -v $1` ] && print_error "Command '$1' not found" || bash -c "$1 $2"; }
function download_image() { run_command "wget" "$1" || print_error "Failed to download $1"; }

# Function to create a new VM in Proxmox and optionally power it on
function create_vm() {
  declare -n ghes_vm=$1
  
  # create VM
  run_command "qm" "create ${ghes_vm[id]} \
    --name '${ghes_vm[hostname]}' \
    --net0 virtio,bridge=${ghes_vm[network]} \
    --ostype l26 \
    --memory ${ghes_vm[memory]} \
    --onboot ${ghes_vm[onboot]} \
    --cpu cputype=${ghes_vm[cputype]} \
    --sockets 1 \
    --cores ${ghes_vm[cores]} \
    --vga qxl" || print_error "Failed to create '${ghes_vm[hostname]}' (${ghes_vm[id]})"

  # import disk image
  run_command "qm" "importdisk ${ghes_vm[id]} 'github-enterprise-${ghes_vm[version]}.qcow2' '${ghes_vm[boot_storage]}'" || print_error "Failed to import root disk"
  
  # add the disk image to the VM
  run_command "qm" "set ${ghes_vm[id]} --scsi0 ${ghes_vm[boot_storage]}:vm-${ghes_vm[id]}-disk-0" || print_error "Failed to configure boot disk"
  
  # set the boot order
  run_command "qm" "set ${ghes_vm[id]} --boot order=scsi0" || error "Failed to configure boot order"
  
  # create data disk on SSD storage
  run_command "pvesm" "alloc '${ghes_vm[ssd_storage]}' '${ghes_vm[id]}' vm-${ghes_vm[id]}-disk-1 ${ghes_vm[userdatasize]}G" || print_error "Failed to allocate storage disk"
  
  # add the disk to the VM
  run_command "qm" "set ${ghes_vm[id]} --scsihw virtio-scsi-pci --scsi1 ${ghes_vm[ssd_storage]}:vm-${ghes_vm[id]}-disk-1,discard=on,ssd=1" || print_error "Failed to configure storage disk"
  
  if [ "${ghes_vm[poweron]}" == "1" ]; then
    run_command "qm" "start ${ghes_vm[id]}" || print_error "Failed to boot"
  fi
}

# Function to configure the initial settings of the VM
#
# This includes setting the root password and uploading the license file
#
# It finds the VM's IP address by pinging the subnet and then configures the VM
# using the curl command to send a POST request to the VM's management endpoint
#
# The function retries the configuration process a few times in case of failure
function initial_config() {
  declare -n ghes_vm=$1

  # Ping every IP in the subnet to hopefully get the VM's IP in the ARP table
  # Each ping times out after 0.2 seconds
  echo "* Attempting to find VM IP address, this might take a few minutes..."
  for ip in $(list_subnet_ips ${ghes_vm[ip_netmask]}); do
    run_command "timeout" "0.2 ping -i 0.2 -c1 $ip > /dev/null 2>&1"
  done

  # get the MAC address of the VM from the proxmox API
  mac_address=$(run_command "pvesh" "get /nodes/$(run_command "hostname")/qemu/${ghes_vm[id]}/config --noborder|grep net0|cut -d ',' -f1|cut -d '=' -f2")
  
  for i in {1..5}; do
    echo -n "* Looking for VM IP address (attempt $i of 5)..."
    
    # get the current ARP table
    ip_address=$(run_command "ip" "neigh show|grep -i $mac_address|grep -v fe80|cut -d ' ' -f 1")

    # try to match the IP address with the MAC address of the VM
    if [ "$ip_address" != "" ]; then
      echo "found $ip_address matching $mac_address"
      for a in {1..5}; do
        echo "* Configuring root site password and uploading license file (attempt $a of 5)..."
        config_output=$(run_command "curl" "${ghes_vm[insecure]} -s -L -X POST -u 'api_key:your-password' -H 'Content-Type: multipart/form-data' https://$ip_address/manage/v1/config/init --form 'license=@${ghes_vm[license_file]}' --form 'password=${ghes_vm[root_password]}' 2>&1")
        if (echo "$config_output" | grep "Sorry"); then
          [ $a -lt 5 ] && sleep 30
        else
          echo "Initial configuration completed. You can finish setting up your GHES instance at https://$ip_address:8443/setup"
          break
        fi
      done

      break
    fi

    [ $i -lt 5 ] && sleep 5
    echo
  done
  if [ "$ip_address" == "" ]; then
    echo "* Failed to find VM IP address"
  fi
}

# Function to convert CIDR to netmask
cidr_to_netmask() {
    local cidr=$1
    local mask=""
    for ((i=1; i<=32; i++)); do
        if [ $i -le $cidr ]; then
            mask="${mask}1"
        else
            mask="${mask}0"
        fi
    done

    echo "$((2#${mask:0:8})).$((2#${mask:8:8})).$((2#${mask:16:8})).$((2#${mask:24:8}))"
}

# Function to generate all IP addresses in a subnet
list_subnet_ips() {
    local network=$(echo $1|cut -d '/' -f 1)
    local cidr=$(echo $1|cut -d '/' -f 2)
    local netmask=$(cidr_to_netmask "$cidr")
    local IFS=.
    read -r i1 i2 i3 i4 <<< "$network"
    read -r m1 m2 m3 m4 <<< "$netmask"

    for ((a=$i1; a<=$((i1|(255-m1))); a++)); do
        for ((b=$i2; b<=$((i2|(255-m2))); b++)); do
            for ((c=$i3; c<=$((i3|(255-m3))); c++)); do
                for ((d=$i4; d<=$((i4|(255-m4))); d++)); do
                    echo "$a.$b.$c.$d"
                done
            done
        done
    done
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
    -u|--userdatasize)
      USERDATAGB="$2"
      shift 2
      ;;
    -c|--cores)
      CORES="$2"
      shift 2
      ;;
    -t|--cputype)
      CPUTYPE="$2"
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
    -r|--root)
      ROOT_PASSWORD="$2"
      shift 2
      ;;
    -l|--license)
      LICENSE_FILE="$2"
      shift 2
      ;;
    -i|--ipnetmask)
      IP_NETMASK="$2"
      shift 2
      ;;
    -p|--poweron)
      POWERON=1
      shift
      ;;
    -o|--onboot)
      ONBOOT="yes"
      shift
      ;;
    -d|--help)
      GHES_DOWNLOAD=1
      shift
      ;;
    -k|--insecure)
      ALLOW_INSECURE="-k"
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
    [cputype]="$CPUTYPE"
    [memory]="$MEMORY"
    [network]="$NETWORK"
    [onboot]="$ONBOOT"
    [poweron]="$POWERON"
    [userdatasize]="$USERDATAGB"
  )
  create_vm new_vm

  if [ -n "$ROOT_PASSWORD" ] && [ -n "$LICENSE_FILE" ]; then
    echo "* Waiting for VM to boot..."
    sleep 45

    declare -A config_vm=(
      [id]="$VM_ID"
      [ip_netmask]="$IP_NETMASK"
      [root_password]="$ROOT_PASSWORD"
      [license_file]="$LICENSE_FILE"
      [insecure]="$ALLOW_INSECURE"
    )

    initial_config config_vm || print_error "Initial configuration failed"
  fi
else
  print_error "Disk image 'github-enterprise-$GHES_VERSION.qcow2' not found"
fi