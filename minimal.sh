#!/bin/bash


console_font="ter-v18n"
wifi_interface="wlan0"
wifi_ssid=""
wifi_passphrase=""
drive="/dev/vda" # run 'lsblk'
efi_part="${drive}1" # 'p1' for NVME
root_part="${drive}2"
luks_label="cryptroot"
luks_passphrase=""
hostname="archlinux"
username=""
user_passphrase=""


# ---------------------------------------------
# Installation
# ---------------------------------------------


# Clean the TTY
clear

# Verify the UEFI mode
if [ ! -d "/sys/firmware/efi/efivars" ]; then
    echo "System is not booted in the UEFI mode"
    exit 1
fi

# Set a custom TTY font
setfont $console_font

# Check internet connection
if ! ping -c 1 archlinux.org > /dev/null; then
    # Unlock all wireless devices
    rfkill unblock all    

    # Connect to the WIFI network
    iwctl --passphrase ${wifi_passphrase} \
          station ${wifi_interface} \
          connect ${wifi_ssid} # use 'connect-hidden' for hidden networks
    wifi=1    

    # Recheck the internet connection
    if ! ping -c 1 archlinux.org > /dev/null; then
        echo "No internet connection"
        exit 1
    fi
fi

# Update the system clock
timedatectl set-ntp true

# Partition
parted --script ${drive} \
       mklabel gpt \
       mkpart "EFI" fat32 0% 513MiB \
       set 1 esp on \
       mkpart "ROOT" btrfs 513MiB 100%

# Encrypt the root partition
echo -n ${luks_passphrase} | cryptsetup --type luks2 \
                                        --cipher aes-xts-plain64 \
                                        --pbkdf argon2id \
                                        --key-size 512 \
                                        --hash sha512 \
                                        --sector-size 4096 \
                                        --use-urandom \
                                        --key-file - \
                                        luksFormat ${root_part}
echo -n ${luks_passphrase} | cryptsetup --key-file - \
                                        luksOpen ${root_part} ${luks_label}

# Format & mount the encrypted root partition
mkfs.btrfs -L "ROOT" /dev/mapper/${luks_label}
mount /dev/mapper/${luks_label} /mnt

# Create BTRFS subvolumes
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@opt
btrfs subvolume create /mnt/@srv
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@swap

# Disable CoW for temporary files and swap
chattr +C /mnt/@tmp
chattr +C /mnt/@swap

# Mount the BTRFS subvolumes 
umount /mnt
mount -o noatime,compress=zstd,commit=120,subvol=@ /dev/mapper/${luks_label} /mnt
mkdir /mnt/{efi,home,opt,srv,tmp,var,swap,.snapshots}
mount -o noatime,compress=zstd,commit=120,subvol=@home /dev/mapper/${luks_label} /mnt/home
mount -o noatime,compress=zstd,commit=120,subvol=@opt /dev/mapper/${luks_label} /mnt/opt
mount -o noatime,compress=zstd,commit=120,subvol=@srv /dev/mapper/${luks_label} /mnt/srv
mount -o noatime,compress=no,nodatacow,subvol=@tmp /dev/mapper/${luks_label} /mnt/tmp
mount -o noatime,compress=zstd,commit=120,subvol=@var /dev/mapper/${luks_label} /mnt/var
mount -o noatime,compress=zstd,commit=120,subvol=@snapshots /dev/mapper/${luks_label} /mnt/.snapshots
mount -o noatime,compress=no,nodatacow,subvol=@swap /dev/mapper/${luks_label} /mnt/swap

# Format & mount the EFI partition
mkfs.fat -F 32 -n "EFI" ${efi_part}
mount ${efi_part} /mnt/efi

# Create a swap file for hibernation
RAM_SIZE=$(( ( $(free -m | awk '/^Mem:/{print $2}') + 1023 ) / 1024 ))
btrfs filesystem mkswapfile --size ${RAM_SIZE}G --uuid clear /mnt/swap/swapfile
swapon /mnt/swap/swapfile

