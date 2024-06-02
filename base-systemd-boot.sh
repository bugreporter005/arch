#!/bin/bash

set -e

console_font="ter-v18n"

wifi_interface="wlan0"
wifi_ssid=""
wifi_passphrase=""

drive="/dev/vda" # run 'lsblk'
efi_part="${drive}1" # 'p1' for NVME
root_part="${drive}2"

hostname="arch"

username=""
user_passphrase=""


# Clean the TTY
clear

# Set a bigger font
setfont $console_font

# Unblock all wireless devices
rfkill unblock all

# Internet connection
if ! ping -c 1 archlinux.org > /dev/null; then
    iwctl --passphrase ${wifi_passphrase} \
          station ${wifi_interface} \
          connect ${wifi_ssid} # use 'connect-hidden' for hidden networks
    #wifi=1
    if ! ping -c 1 archlinux.org > /dev/null; then
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

# Format and mount the encrypted root partition
mkfs.btrfs -L ROOT ${root_part}
mount ${root_part} /mnt

# Create BTRFS subvolumes
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@opt
btrfs subvolume create /mnt/@srv
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@swap

# Disable CoW on certain subvolumes
chattr +C /mnt/@tmp
chattr +C /mnt/@swap

# Mount the BTRFS subvolumes 
umount /mnt
mount -o noatime,compress=zstd,commit=120,subvol=@ ${root_part} /mnt
mkdir /mnt/{boot,home,opt,srv,tmp,var,swap,.snapshots}
mount -o noatime,compress=zstd,commit=120,subvol=@home ${root_part} /mnt/home
mount -o noatime,compress=zstd,commit=120,subvol=@opt ${root_part} /mnt/opt
mount -o noatime,compress=zstd,commit=120,subvol=@srv ${root_part} /mnt/srv
mount -o noatime,compress=no,nodatacow,subvol=@tmp ${root_part} /mnt/tmp
mount -o noatime,compress=zstd,commit=120,subvol=@var ${root_part} /mnt/var
mount -o noatime,compress=zstd,commit=120,subvol=@snapshots ${root_part} /mnt/.snapshots
mount -o noatime,compress=no,nodatacow,subvol=@swap ${root_part} /mnt/swap

# Swap file to set up hibernation
ram_size=$(( ( $(free -m | awk '/^Mem:/{print $2}') + 1023 ) / 1024 ))
btrfs filesystem mkswapfile --size ${ram_size}G --uuid clear /mnt/swap/swapfile
swapon /mnt/swap/swapfile

# Format and mount the EFI partition
mkfs.fat -F 32 -n EFI ${efi_part}
mount ${efi_part} /mnt/boot

# Mirror setup and enable parallel download in Pacman
reflector --latest 5 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
sed -i "/ParallelDownloads/s/^#//g" /etc/pacman.conf
sed -i "s/ParallelDownloads = 5/ParallelDownloads = 5\nDisableDownloadTimeout/" /etc/pacman.conf

# Update keyrings to prevent packages failing to install
pacman -Sy archlinux-keyring --noconfirm

# Virtual machine detection for package exclusions
if [ systemd-detect-virt == "none" ]; then
    # CPU vendor detection for microcode installation
    cpu_vendor=$(lscpu | grep -e '^Vendor ID' | awk '{print $3}')
    if [ "$cpu_vendor" == "AuthenticAMD" ]; then
        microcode="amd-ucode"
    elif [ "$cpu_vendor" == "GenuineIntel" ]; then
        microcode="intel-ucode"
    else
        echo "Unsupported vendor $cpu_vendor"
        exit 1
    fi
    linux_firmware="linux-firmware"
else
    microcode=""
    linux_firmware=""
fi

# Installation of essential packages
pacstrap -K /mnt \
    base base-devel \
    linux-lts ${linux_firmware} ${microcode} \
    zram-generator \
    btrfs-progs snapper snap-pac \
    plymouth \
    networkmanager \
    reflector \
    terminus-font \
    zsh zsh-completions \
    neovim \
    git

# Generate fstab
genfstab -U /mnt > /mnt/etc/fstab

# ZRAM configuration
if [ $ram_size -le 64 ]; then
    cat > /mnt/etc/systemd/zram-generator.conf << EOF
[zram0]
zram-size = ram * 2
compression-algorithm = zstd
EOF
    arch-chroot /mnt systemctl daemon-reload
    arch-chroot /mnt systemctl start systemd-zram-setup@zram0.service
fi

# Set timezone based on IP address
arch-chroot /mnt ln -sf /usr/share/zoneinfo/$(curl https://ipapi.co/timezone) /etc/localtime
arch-chroot /mnt hwclock --systohc

# Localization
arch-chroot /mnt sed -i "/en_US.UTF-8/s/^#//" /etc/locale.gen
arch-chroot /mnt sed -i "/ru_RU.UTF-8/s/^#//" /etc/locale.gen
arch-chroot /mnt sed -i "/kk_KZ.UTF-8/s/^#//" /etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
echo "FONT=${console_font}" > /mnt/etc/vconsole.conf

# Network configuration
echo "${hostname}" > /mnt/etc/hostname
ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
arch-chroot /mnt systemctl enable systemd-resolved.service

# Initramfs
sed -i "s/MODULES=(.*)/MODULES=(btrfs)/" /mnt/etc/mkinitcpio.conf
sed -i "s/BINARIES=(.*)/BINARIES=(\/usr\/bin\/btrfs)/" /mnt/etc/mkinitcpio.conf
if [ "$microcode" == "" ]; then
    sed -i "s/HOOKS=(.*)/HOOKS=(base systemd plymouth autodetect modconf sd-vconsole block btrfs filesystems keyboard fsck)/" /mnt/etc/mkinitcpio.conf
else
    sed -i "s/HOOKS=(.*)/HOOKS=(base systemd plymouth autodetect microcode modconf sd-vconsole block btrfs filesystems keyboard fsck)/" /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -P

# User management
arch-chroot /mnt useradd -m -G wheel -s /bin/zsh ${username}
echo "${username}:${user_passphrase}" | arch-chroot /mnt chpasswd
arch-chroot /mnt passwd --delete root && passwd --lock root # disable the root user
sed -i "/%wheel ALL=(ALL:ALL) ALL/s/^#//" /mnt/etc/sudoers # give the wheel group sudo access

# Bootloader
ROOT_UUID=$(blkid -o value -s UUID ${root_part})
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /mnt/swap/swapfile)
bootctl install
arch-chroot /mnt cat > /boot/loader/entries/archlinux.conf << EOF
title   Arch Linux
initrd  /initramfs-linux-lts.img
linux   /vmlinuz-linux-lts
options root=UUID=${ROOT_UUID} rootflags=subvol=/@ rw 
options quiet splash loglevel=3 rd.udev.log_priority=3
options resume=UUID=${ROOT_UUID} resume_offset=${RESUME_OFFSET}
EOF
arch-chroot /mnt cat > /boot/loader/loader.conf << EOF
timeout 3
default archlinux.conf
console-mode max
editor no
EOF

# Pacman configuration
arch-chroot /mnt cat > /etc/xdg/reflector/reflector.conf << EOF
--latest 5
--protocol https
--sort rate
--save /etc/pacman.d/mirrorlist
EOF
arch-chroot /mnt systemctl enable reflector.service
sed -i "/Color/s/^#//" /mnt/etc/pacman.conf
sed -i "/VerbosePkgLists/s/^#//g" /mnt/etc/pacman.conf
sed -i "/ParallelDownloads/s/^#//g" /mnt/etc/pacman.conf
sed -i "s/ParallelDownloads = 5/ParallelDownloads = 5\nILoveCandy/" /mnt/etc/pacman.conf

# Internet
arch-chroot /mnt systemctl enable NetworkManager.service
