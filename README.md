```
Creates and boots a new GitHub Enterprise Server appliance in Proxmox.

OPTIONS:
   -v  |  --version      Version of GHES to install
   -h  |  --hostname     Hostname for new virtual machine.
   -b  |  --bootstorage  Name of boot disk storage.
   -s  |  --ssdstorage   Name of SSD storage.
   -c  |  --cores        Number of vCPU cores. Default: 8
   -m  |  --memory       Amount of RAM in megabytes. Default: 65535
   -n  |  --network      Network device name. Default: vmbr0
   -d  |  --download     Download QCOW2 image for specified version.

EXAMPLE:
 
Download GHES version 3.15.4, import it into "local" storage as "ghes-primary",
create a data drive on "local-ssd" storage, create a VM with 8 cores, 64GB ram,
and use the configured "vmbr0" network bridge
 
 gheboot.sh -v 3.15.4 -h ghes-primary -b local -s local-ssd -c 8 -m 65535 -n vmbr0 -d
```
