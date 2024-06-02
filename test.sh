#!/bin/bash

set -e

console_font="ter-v18n"

wifi_interface="wlan0"
wifi_ssid=""
wifi_passphrase=""

drive="/dev/vda" # run 'lsblk'
efi_part="${drive}1" # 'p1' for NVME
root_part="${drive}2"

luks_label="cryptroot"
luks_passphrase=""

hostname="arch"

username=""
user_passphrase=""



# Clean the TTY
clear

# Set a bigger font
setfont $console_font

# Update the system clock
timedatectl set-ntp true

# Partition
parted --script ${drive} \
       mklabel gpt \
       mkpart EFI fat32 0% 513MiB \
       set 1 esp on \
       mkpart ROOT btrfs 513MiB 100%

# Encryption
echo -n ${luks_passphrase} | cryptsetup -q \
                                        --type luks2 \
                                        --pbkdf argon2id \
                                        --key-size 512 \
                                        --hash sha512 \
                                        --sector-size 4096 \
                                        --use-random \
                                        luksFormat ${root_part}
echo -n ${luks_passphrase} | cryptsetup luksOpen ${root_part} ${luks_label}

# Format and mount the encrypted root partition
mkfs.btrfs -L ROOT /dev/mapper/${luks_label}
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

# Disable CoW on certain subvolumes
chattr +C /mnt/@tmp
chattr +C /mnt/@swap

# Mount the BTRFS subvolumes 
umount /mnt
mount -o noatime,compress=zstd,commit=120,subvol=@ /dev/mapper/${luks_label} /mnt
mkdir /mnt/{boot,home,opt,srv,tmp,var,swap,.snapshots}
mount -o noatime,compress=zstd,commit=120,subvol=@home /dev/mapper/${luks_label} /mnt/home
mount -o noatime,compress=zstd,commit=120,subvol=@opt /dev/mapper/${luks_label} /mnt/opt
mount -o noatime,compress=zstd,commit=120,subvol=@srv /dev/mapper/${luks_label} /mnt/srv
mount -o noatime,compress=no,nodatacow,subvol=@tmp /dev/mapper/${luks_label} /mnt/tmp
mount -o noatime,compress=zstd,commit=120,subvol=@var /dev/mapper/${luks_label} /mnt/var
mount -o noatime,compress=zstd,commit=120,subvol=@snapshots /dev/mapper/${luks_label} /mnt/.snapshots
mount -o noatime,compress=no,nodatacow,subvol=@swap /dev/mapper/${luks_label} /mnt/swap

# Format and mount the EFI partition
mkfs.fat -F 32 -n EFI ${efi_part}
mount ${efi_part} /mnt/boot

# Mirror setup and enable parallel download in Pacman
reflector --latest 5 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
sed -i "/ParallelDownloads/s/^#//g" /etc/pacman.conf
sed -i "s/ParallelDownloads = 5/ParallelDownloads = 5\nDisableDownloadTimeout/" /etc/pacman.conf

# Update keyrings to prevent packages failing to install
pacman -Sy archlinux-keyring --noconfirm

# Installation of essential packages
pacstrap -K /mnt \
    base base-devel \
    linux-lts \
    zram-generator \
    cryptsetup \
    btrfs-progs snapper snap-pac \
    plymouth \
    networkmanager \
    terminus-font \
    zsh zsh-completions \
    neovim \
    git

# Generate fstab
genfstab -U /mnt > /mnt/etc/fstab

# Set timezone based on IP address
arch-chroot /mnt ln -sf /usr/share/zoneinfo/$(curl https://ipapi.co/timezone) /etc/localtime
arch-chroot /mnt hwclock --systohc

# Localization
arch-chroot /mnt sed -i "/en_US.UTF-8/s/^#//" /etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
echo "FONT=${console_font}" > /mnt/etc/vconsole.conf

# Network configuration
echo "${hostname}" > /mnt/etc/hostname

# Initramfs
sed -i "s/MODULES=(.*)/MODULES=(btrfs)/" /mnt/etc/mkinitcpio.conf
sed -i "s/BINARIES=(.*)/BINARIES=(\/usr\/bin\/btrfs)/" /mnt/etc/mkinitcpio.conf
sed -i "s/HOOKS=(.*)/HOOKS=(base systemd plymouth autodetect modconf sd-vconsole block sd-encrypt btrfs filesystems keyboard fsck)/" /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -P

# User management
arch-chroot /mnt useradd -m -G wheel -s /bin/zsh ${username}
echo "${username}:${user_passphrase}" | arch-chroot /mnt chpasswd
sed -i "/%wheel ALL=(ALL:ALL) ALL/s/^#//" /mnt/etc/sudoers # give the wheel group sudo access

# Bootloader
ROOT_UUID=$(blkid -o value -s UUID ${root_part})
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /mnt/swap/swapfile)
bootctl install
arch-chroot /mnt cat > /boot/loader/entries/archlinux.conf << EOF
title   Arch Linux
initrd  /initramfs-linux-lts.img
linux   /vmlinuz-linux-lts
options rd.luks.name=${ROOT_UUID}=${luks_label} rd.luks.options=tries=3,discard,no-read-workqueue,no-write-workqueue root=/dev/mapper/${luks_label} rootflags=subvol=/@ rw 
options quiet splash loglevel=3 rd.udev.log_priority=3
options resume=/dev/mapper/${luks_label} resume_offset=${RESUME_OFFSET}
EOF
#options cryptkey=rootfs:/root/.cryptkey/keyfile.bin
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

# Reboot
#umount -a
#cryptsetup close ${luks_label}
#reboot
