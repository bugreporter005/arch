#!/bin/bash


console_font="ter-v18n"

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


set -e


# Clean the TTY
clear


# Check if it's Arch Linux
if [ ! -e /etc/arch-release ]; then
    echo "This script must be run in Arch Linux!"
    exit 1
fi


# Verify the UEFI mode
if [ ! -d /sys/firmware/efi/efivars ]; then
    echo "System is not booted in the UEFI mode!"
    exit 1
fi


# Set a custom TTY font
setfont $console_font


# Update the system clock
timedatectl set-ntp true


# Partition
parted --script ${drive} \
       mklabel gpt \
       mkpart EFI fat32 0% 513MiB \
       set 1 esp on \
       mkpart root btrfs 513MiB 100%


# Encrypt the root partition (use 'argon2id' for GRUB 2.13+)
echo -n ${luks_passphrase} | cryptsetup --type luks2 \
                                        --cipher aes-xts-plain64 \
                                        --pbkdf pbkdf2 \
                                        --key-size 512 \
                                        --hash sha512 \
                                        --sector-size 4096 \
                                        --use-urandom \
                                        --key-file - \
                                        luksFormat ${root_part}

echo -n ${luks_passphrase} | cryptsetup --key-file - \
                                        luksOpen ${root_part} ${luks_label}


# Create filesystems
mkfs.fat -F 32 -n "EFI" ${efi_part}
mkfs.btrfs -L root /dev/mapper/${luks_label}


# Configure BTRFS subvolumes
mount LABEL=root /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@cryptkey


# Disable CoW for the LUKS keyfile
chattr +C /mnt/@cryptkey


# Mount the BTRFS subvolumes and the EFI partition
umount /mnt

mount -o noatime,compress=zstd,commit=120,subvol=@ /dev/mapper/${luks_label} /mnt

mkdir -p /mnt/{root/.cryptkey,boot/EFI,home}

mount -o noatime,compress=zstd,commit=120,subvol=@home /dev/mapper/${luks_label} /mnt/home
mount -o noatime,compress=no,nodatacow,subvol=@cryptkey /dev/mapper/${luks_label} /mnt/root/.cryptkey

mount ${efi_part} /mnt/boot/EFI


# Setup mirrors & enable parallel downloading in Pacman
reflector --latest 5 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

sed -i "/ParallelDownloads/s/^#//g" /etc/pacman.conf
sed -i "s/ParallelDownloads = 5/ParallelDownloads = 5\nDisableDownloadTimeout/" /etc/pacman.conf


# Update keyrings to prevent packages failing to install
pacman -Sy archlinux-keyring --noconfirm


# Install essential packages
pacstrap -K /mnt \
    base \
    sudo \
    linux-lts \
    cryptsetup \
    grub efibootmgr \
    btrfs-progs \
    networkmanager \
    terminus-font \
    neovim


# Generate fstab & remove subvolids to boot into snapshots
genfstab -U /mnt > /mnt/etc/fstab


# Set timezone based on IP address
arch-chroot /mnt ln -sf /usr/share/zoneinfo/$(curl https://ipapi.co/timezone) /etc/localtime
arch-chroot /mnt hwclock --systohc


# Locales
arch-chroot /mnt sed -i "/en_US.UTF-8/s/^#//" /etc/locale.gen

arch-chroot /mnt locale-gen

cat > /mnt/etc/locale.conf << EOF
LANG=en_US.UTF-8
LC_MEASUREMENT=en_GB.UTF-8
EOF

echo "FONT=${console_font}" > /mnt/etc/vconsole.conf


# Network
echo "${hostname}" > /mnt/etc/hostname
ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
arch-chroot /mnt systemctl enable systemd-resolved.service
arch-chroot /mnt systemctl enable NetworkManager.service


# Initramfs
sed -i "s/MODULES=(.*)/MODULES=(btrfs)/" /mnt/etc/mkinitcpio.conf
sed -i "s/BINARIES=(.*)/BINARIES=(\/usr\/bin\/btrfs)/" /mnt/etc/mkinitcpio.conf
sed -i "s/HOOKS=(.*)/HOOKS=(base systemd autodetect modconf sd-vconsole block sd-encrypt btrfs filesystems keyboard fsck)/" /mnt/etc/mkinitcpio.conf

arch-chroot /mnt mkinitcpio -P


# Manage users
arch-chroot /mnt useradd -m -G wheel -s /bin/bash ${username}
echo "${username}:${user_passphrase}" | arch-chroot /mnt chpasswd
sed -i "/%wheel ALL=(ALL:ALL) ALL/s/^#//" /mnt/etc/sudoers

arch-chroot /mnt passwd --delete root && passwd --lock root


# Automate mirror update & configure Pacman
sed -i "/Color/s/^#//" /mnt/etc/pacman.conf
sed -i "/VerbosePkgLists/s/^#//g" /mnt/etc/pacman.conf
sed -i "/ParallelDownloads/s/^#//g" /mnt/etc/pacman.conf
sed -i "s/ParallelDownloads = 5/ParallelDownloads = 5\nILoveCandy/" /mnt/etc/pacman.conf


# Embed a keyfile in initramfs to avoid having to enter the encryption passphrase twice
chmod 700 /mnt/root/.cryptkey
head -c 64 /dev/urandom > /mnt/root/.cryptkey/keyfile.bin
chmod 600 /mnt/root/.cryptkey/keyfile.bin
echo -n ${luks_passphrase} | cryptsetup luksAddKey ${root_part} /mnt/root/.cryptkey/keyfile.bin


# Bootloader
ROOT_UUID=$(blkid -o value -s UUID ${root_part})

sed -i "/GRUB_ENABLE_CRYPTODISK=y/s/^#//" /mnt/etc/default/grub
sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.name=${ROOT_UUID}=${luks_label} rd.luks.options=tries=3,discard,no-read-workqueue,no-write-workqueue root=/dev/mapper/${luks_label} rootflags=subvol=/@ rw cryptkey=rootfs:/root/.cryptkey/keyfile.bin quiet splash loglevel=3 rd.udev.log_priority=3\"|" /mnt/etc/default/grub

arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot/EFI --bootloader-id=GRUB
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

chmod 700 /mnt/boot


# Backup LUKS header
cryptsetup luksHeaderBackup ${root_part} --header-backup-file /mnt/home/${username}/luks_header.bin


# Reboot
#reboot
