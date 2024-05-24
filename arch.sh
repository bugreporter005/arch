#!/bin/bash

# Clean the TTY
clear


# Set a bigger font
setfont $console_font


# Unblock all wireless devices
rfkill unblock all


# Internet connection
if ! ping -c 2 archlinux.org > /dev/null; then
    iwctl --passphrase ${wifi_passphrase} station ${wifi_interface} connect ${wifi_SSID} # use 'connect-hidden' for hidden networks
    if ! ping -c 2 archlinux.org > /dev/null; then
        echo "No internet connection"
        exit 1
    fi
fi


# Update the system clock
timedatectl set-ntp true


# Verify the UEFI mode 
if [ ! -d "/sys/firmware/efi/efivars" ]; then
    echo "System is not booted in the UEFI mode"
    exit 1
fi


# Partition
parted --script ${drive} \
       mklabel gpt \
       mkpart EFI fat32 0% 513MiB \
       set 1 esp on \
       mkpart ROOT btrfs 513MiB 100%


# Encryption
echo -n ${luks_passphrase} | cryptsetup -q --type luks2 --key-size 512 --hash sha512 --use-random --key-file - luksFormat ${root_partition}
echo -n ${luks_passphrase} | cryptsetup luksOpen ${root_partition} ${luks_label}


# Format and mount the encrypted root partition
mkfs.btrfs -L ROOT /dev/mapper/${luks_label}
mount /dev/mapper/${luks_label} /mnt


# Create BTRFS subvolumes
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@pkg
btrfs subvolume create /mnt/@docker
btrfs subvolume create /mnt/@vm
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@swap


# Mount the BTRFS subvolumes 
umount /mnt
mount -o noatime,compress=zstd,commit=120,subvol=@ /dev/mapper/${luks_label} /mnt
mkdir -p /mnt/{boot,efi,home,swap,.snapshots,tmp,var/log,var/cache/pacman/pkg,var/lib/docker,var/lib/libvirt}
mount -o subvol=@home /dev/mapper/${luks_label} /mnt/home
mount -o subvol=@tmp /dev/mapper/${luks_label} /mnt/tmp
mount -o subvol=@log /dev/mapper/${luks_label} /mnt/var/log
mount -o subvol=@pkg /dev/mapper/${luks_label} /mnt/var/cache/pacman/pkg
mount -o subvol=@docker /dev/mapper/${luks_label} /mnt/var/lib/docker
mount -o subvol=@vm /dev/mapper/${luks_label} /mnt/var/lib/libvirt
mount -o subvol=@snapshots dev/mapper/${luks_label} /mnt/.snapshots
mount -o subvol=@swap /dev/mapper/${luks_label} /mnt/swap


# Format and mount the EFI partition
mkfs.fat -F 32 -n EFI ${efi_partition}
mount ${efi_partition} /mnt/efi


# Swap file (double of the size of memory)
# TODO: Check if it works
#RAM=$(free -m | awk '/^Mem:/{print $2}')
#btrfs filesystem mkswapfile --size $((RAM * 2))m --uuid clear /mnt/swap/swapfile
#swapon /mnt/swap/swapfile


# Set up mirrors
reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist


# Enable parralel downloads
sed -i "s/#ParallelDownloads = 5/ParallelDownloads = 5\nILoveCandy/" /etc/pacman.conf


# Update keyrings to prevent packages failing to install
pacman -Sy archlinux-keyring --noconfirm


# Detect CPU vendor
cpu_vendor=$(lscpu | grep -e '^Vendor ID' | awk '{print $3}')
if [ "$cpu_vendor" == "AuthenticAMD" ]; then
    microcode="amd-ucode"
elif [ "$cpu_vendor" == "GenuineIntel" ]; then
    microcode="intel-ucode"
else
  echo "Unsupported vendor $cpu_vendor"
  exit 1
fi


# Install base packages
pacstrap -K /mnt \
    base base-devel \
    linux-lts linux-firmware \
    ${microcode} \
    cryptsetup \
    btrfs-progs snapper \
    efibootmgr \
    plymouth \
    networkmanager \
    terminus-font \
    zsh neovim git


# Generate fstab
genfstab -U /mnt > /mnt/etc/fstab


# Change root into the new system
cp -a *.sh /mnt/root/
arch-chroot /mnt /mnt/root/chroot.sh
