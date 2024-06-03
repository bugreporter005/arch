#!/bin/bash

set -e

console_font="ter-v18n"
drive="/dev/vda"
efi_part="${drive}1"
root_part="${drive}2"
luks_label="cryptroot"
luks_password=""
hostname="linux"
username=""
user_password=""



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
echo ${luks_password} | cryptsetup --type luks2 --cipher aes-xts-plain64 --pbkdf pbkdf2 --key-size 512 --hash sha512 --use-urandom --key-file - luksFormat ${root_part}
echo ${luks_password} | cryptsetup --key-file - luksOpen ${root_part} ${luks_label}

# Format and mount the encrypted root partition
mkfs.btrfs -L ROOT /dev/mapper/${luks_label}
mount /dev/mapper/${luks_label} /mnt

# Create BTRFS subvolumes
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@swap

# Mount the BTRFS subvolumes 
umount /mnt
mount -o noatime,compress=zstd,commit=120,subvol=@ /dev/mapper/${luks_label} /mnt
mkdir /mnt/{boot,efi,home,swap,.snapshots}
mount -o noatime,compress=zstd,commit=120,subvol=@home /dev/mapper/${luks_label} /mnt/home
mount -o noatime,compress=zstd,commit=120,subvol=@snapshots /dev/mapper/${luks_label} /mnt/.snapshots
mount -o noatime,compress=no,nodatacow,subvol=@swap /dev/mapper/${luks_label} /mnt/swap

# Format and mount the EFI partition
mkfs.fat -F 32 -n EFI ${efi_part}
mount ${efi_part} /mnt/efi

# Mirror setup and enable parallel download in Pacman
reflector --latest 5 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
sed -i "/ParallelDownloads/s/^#//g" /etc/pacman.conf
sed -i "s/ParallelDownloads = 5/ParallelDownloads = 5\nDisableDownloadTimeout/" /etc/pacman.conf

# Update keyrings to prevent packages failing to install
pacman -Sy archlinux-keyring --noconfirm

# Installation of essential packages
pacstrap -K /mnt base linux-lts cryptsetup grub efibootmgr grub-btrfs btrfs-progs snapper networkmanager terminus-font neovim

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
sed -i "s/HOOKS=(.*)/HOOKS=(base systemd autodetect modconf sd-vconsole block sd-encrypt btrfs filesystems keyboard fsck)/" /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -P

# User management
arch-chroot /mnt useradd -m -G wheel -s /bin/bash ${username}
echo "${username}:${user_password}" | arch-chroot /mnt chpasswd
sed -i "/%wheel ALL=(ALL:ALL) ALL/s/^#//" /mnt/etc/sudoers # give the wheel group sudo access

# Bootloader
ROOT_UUID=$(blkid -o value -s UUID ${root_part})
sed -i "/GRUB_ENABLE_CRYPTODISK=y/s/^#//" /mnt/etc/default/grub
sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.name=${ROOT_UUID}=${luks_label} rd.luks.options=discard root=/dev/mapper/${luks_label} rootflags=subvol=/@ rw quiet splash\"|" /mnt/etc/default/grub
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# Internet
arch-chroot /mnt systemctl enable NetworkManager.service
