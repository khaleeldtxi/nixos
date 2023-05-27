setfont ter-v22b
clear

echo -ne "
-------------------------------------------------------------------------
                          Disk Preparation
-------------------------------------------------------------------------
"

# Selecting the target for the installation.
lsblk -n --output TYPE,KNAME,SIZE | awk '$1=="disk"{print NR,"/dev/"$2" - "$3}'
echo -ne "
------------------------------------------------------------------------
    THIS WILL FORMAT AND DELETE ALL DATA ON THE DISK             
    Please make sure you know what you are doing because         
    after formating your disk there is no way to get data back      
------------------------------------------------------------------------
"
read -p "Please enter full path to disk: (example /dev/sda or /dev/nvme0n1 or /dev/vda): " DISK

# Set a mount point
MNT=$(mktemp -d)

# Set swap size in GB, set to 1 if you don’t want swap to take up too much space
SWAPSIZE=4

# Set how much space should be left at the end of the disk, minimum 1GB
RESERVE=1

#Enable Nix Flakes functionality:
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf

# Install programs needed for system installation
if ! command -v git; then nix-env -f '<nixpkgs>' -iA git; fi
if ! command -v jq;  then nix-env -f '<nixpkgs>' -iA jq; fi
if ! command -v partprobe;  then nix-env -f '<nixpkgs>' -iA parted; fi


# disk prep
# Deleting old partition scheme.
read -r -p "This will delete the current partition table on $DISK. Do you agree [y/N]? " response
response=${response,,}
if [[ "$response" =~ ^(yes|y)$ ]]; then
    echo -ne "
    -------------------------------------------------------------------------
                                Formating Disk
    -------------------------------------------------------------------------
    "
    wipefs -af $DISK &>/dev/null
    sgdisk -Zo $DISK &>/dev/null
    
    partition_disk () {
    local disk="${1}"
    
    parted --script --align=optimal  "${disk}" -- \
    mklabel gpt \
    mkpart EFI 2MiB 1GiB \
    mkpart bpool 1GiB 5GiB \
    mkpart rpool 5GiB -$((SWAPSIZE + RESERVE))GiB \
    mkpart swap  -$((SWAPSIZE + RESERVE))GiB -"${RESERVE}"GiB \
    mkpart BIOS 1MiB 2MiB \
    set 1 esp on \
    set 5 bios_grub on \
    set 5 legacy_boot on

    partprobe "${disk}"
    udevadm settle
    }

    for i in ${DISK}; do
       partition_disk "${i}"
    done
 
 else
    echo "Quitting."
    exit
fi


# Create boot pool
# shellcheck disable=SC2046
zpool create \
    -o compatibility=grub2 \
    -o ashift=12 \
    -o autotrim=on \
    -O acltype=posixacl \
    -O canmount=off \
    -O compression=lz4 \
    -O devices=off \
    -O normalization=formD \
    -O relatime=on \
    -O xattr=sa \
    -O mountpoint=/boot \
    -R "${MNT}" \
    bpool \
    $(for i in ${DISK}; do
       printf '%s ' "${i}-part2";
    done)
      
# Create root pool
# shellcheck disable=SC2046
zpool create \
    -o ashift=12 \
    -o autotrim=on \
    -R "${MNT}" \
    -O acltype=posixacl \
    -O canmount=off \
    -O compression=zstd \
    -O dnodesize=auto \
    -O normalization=formD \
    -O relatime=on \
    -O xattr=sa \
    -O mountpoint=/ \
    rpool \
    $(for i in ${DISK}; do
      printf '%s ' "${i}-part3";
     done)

#Create root system container:
zfs create \
 -o canmount=off \
 -o mountpoint=none \
rpool/nixos

# Create system datasets, manage mountpoints with mountpoint=legacy
zfs create -o mountpoint=legacy     rpool/nixos/root
mount -t zfs rpool/nixos/root "${MNT}"/
zfs create -o mountpoint=legacy rpool/nixos/home
mkdir "${MNT}"/home
mount -t zfs rpool/nixos/home "${MNT}"/home
zfs create -o mountpoint=legacy  rpool/nixos/var
zfs create -o mountpoint=legacy rpool/nixos/var/lib
zfs create -o mountpoint=legacy rpool/nixos/var/log
zfs create -o mountpoint=none bpool/nixos
zfs create -o mountpoint=legacy bpool/nixos/root
mkdir "${MNT}"/boot
mount -t zfs bpool/nixos/root "${MNT}"/boot
mkdir -p "${MNT}"/var/log
mkdir -p "${MNT}"/var/lib
mount -t zfs rpool/nixos/var/lib "${MNT}"/var/lib
mount -t zfs rpool/nixos/var/log "${MNT}"/var/log
zfs create -o mountpoint=legacy rpool/nixos/empty
zfs snapshot rpool/nixos/empty@start

# Format and mount ESP
for i in ${DISK}; do
 mkfs.vfat -n EFI "${i}"-part1
 mkdir -p "${MNT}"/boot/efis/"${i##*/}"-part1
 mount -t vfat -o iocharset=iso8859-1 "${i}"-part1 "${MNT}"/boot/efis/"${i##*/}"-part1
done


# System Configuration

# Clone template flake configuration
mkdir -p "${MNT}"/etc
git clone --depth 1 --branch openzfs-guide \
  https://github.com/ne9z/dotfiles-flake.git "${MNT}"/etc/nixos
  
# From now on, the complete configuration of the system will be tracked by git, set a user name and email address to continue
rm -rf "${MNT}"/etc/nixos/.git
git -C "${MNT}"/etc/nixos/ init -b main
git -C "${MNT}"/etc/nixos/ add "${MNT}"/etc/nixos/
git -C "${MNT}"/etc/nixos config user.email "khaleeldtxi@outlook.com"
git -C "${MNT}"/etc/nixos config user.name "khaleeldtxi"
git -C "${MNT}"/etc/nixos commit -asm 'initial commit'

# Customize configuration to your hardware
for i in ${DISK}; do
  sed -i \
  "s|/dev/disk/by-id/|${i%/*}/|" \
  "${MNT}"/etc/nixos/hosts/exampleHost/default.nix
  break
done

diskNames=""
for i in ${DISK}; do
  diskNames="${diskNames} \"${i##*/}\""
done

sed -i "s|\"bootDevices_placeholder\"|${diskNames}|g" \
  "${MNT}"/etc/nixos/hosts/exampleHost/default.nix

sed -i "s|\"abcd1234\"|\"$(head -c4 /dev/urandom | od -A none -t x4| sed 's| ||g' || true)\"|g" \
  "${MNT}"/etc/nixos/hosts/exampleHost/default.nix

sed -i "s|\"x86_64-linux\"|\"$(uname -m || true)-linux\"|g" \
  "${MNT}"/etc/nixos/flake.nix

cp "$(command -v nixos-generate-config || true)" ./nixos-generate-config

chmod a+rw ./nixos-generate-config

# shellcheck disable=SC2016
echo 'print STDOUT $initrdAvailableKernelModules' >> ./nixos-generate-config

kernelModules="$(./nixos-generate-config --show-hardware-config --no-filesystems | tail -n1 || true)"

sed -i "s|\"kernelModules_placeholder\"|${kernelModules}|g" \
  "${MNT}"/etc/nixos/hosts/exampleHost/default.nix
  
  
# Commit changes to local repo
git -C "${MNT}"/etc/nixos commit -asm 'initial installation'

# Update flake lock file to track latest system version
nix flake update --commit-lock-file \
  "git+file://${MNT}/etc/nixos"
  
# Install system and apply configuration
nixos-install \
--root "${MNT}" \
--no-root-passwd \
--flake "git+file://${MNT}/etc/nixos#exampleHost"


# Unmount filesystems
umount -Rl "${MNT}"
zpool export -a

# Reboot
reboot
