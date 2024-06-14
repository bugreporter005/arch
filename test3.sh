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


# Check internet connection
if [ ! ping -c 1 archlinux.org > /dev/null ]; then
    echo "No internet connection!"
    exit 1
fi


# Update the system clock
timedatectl set-ntp true


# Partition
sgdisk --zap-all $drive

parted --script $drive \
       mklabel gpt \
       mkpart EFI fat32 0% 301MiB \
       set 1 esp on \
       mkpart root btrfs 301MiB 100%


# Encrypt the root partition
echo -n $luks_passphrase | cryptsetup --type luks2 \
                                      --cipher aes-xts-plain64 \
                                      --pbkdf argon2id \
                                      --key-size 512 \
                                      --hash sha512 \
                                      --sector-size 4096 \
                                      --use-urandom \
                                      --key-file - \
                                      luksFormat ${root_part}

echo -n $luks_passphrase | cryptsetup --key-file - \
                                      luksOpen ${root_part} ${luks_label}


# Create filesystems
mkfs.fat -F 32 -n EFI $efi_part
mkfs.btrfs -L root /dev/mapper/${luks_label}


# Configure BTRFS subvolumes
mount LABEL=root /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@cryptkey


# Disable CoW
chattr +C /mnt/@cryptkey


# Mount the BTRFS subvolumes and partitions
umount /mnt

mount -o noatime,compress=zstd,commit=120,discard=async,space_cache=v2,subvol=@ /dev/mapper/${luks_label} /mnt

mkdir -p /mnt/{efi,home,.cryptkey}

mount -o noatime,compress=zstd,commit=120,discard=async,space_cache=v2,subvol=@home /dev/mapper/${luks_label} /mnt/home
mount -o noatime,compress=no,nodatacow,discard=async,space_cache=v2,subvol=@cryptkey /dev/mapper/${luks_label} /mnt/.cryptkey

mount LABEL=EFI /mnt/efi


# Setup mirrors
reflector --latest 5 \
          --age 12 \
          --protocol https \
          --sort rate \
          --save /etc/pacman.d/mirrorlist


# Enable parallel downloading & disable download timeout in Pacman
sed -i "/ParallelDownloads/s/^#//g" /etc/pacman.conf
sed -i "s/ParallelDownloads = 5/ParallelDownloads = 5\nDisableDownloadTimeout/" /etc/pacman.conf


# Update keyrings to prevent packages failing to install
pacman -Sy --needed --noconfirm archlinux-keyring


# Install essential packages
pacstrap -K /mnt \
    base base-devel \
    linux-lts \
    cryptsetup \
    efibootmgr \
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
echo $hostname > /mnt/etc/hostname

arch-chroot /mnt systemctl enable NetworkManager.service


# LUKS keyfile to avoid having to enter the encryption passphrase twice
chmod 700 /mnt/.cryptkey
head -c 64 /dev/urandom > /mnt/.cryptkey/root.key
chmod 000 /mnt/.cryptkey/root.key

echo -n $luks_passphrase | cryptsetup luksAddKey $root_part /mnt/.cryptkey/root.key


# Initramfs
sed -i "s/MODULES=(.*)/MODULES=(btrfs)/" /mnt/etc/mkinitcpio.conf
sed -i "s/FILES=(.*)/FILES=(/.cryptkey/root.key)/" /mnt/etc/mkinitcpio.conf
sed -i "s/BINARIES=(.*)/BINARIES=(\/usr\/bin\/btrfs)/" /mnt/etc/mkinitcpio.conf
sed -i "s/HOOKS=(.*)/HOOKS=(base systemd autodetect modconf sd-vconsole block sd-encrypt btrfs filesystems keyboard fsck)/" /mnt/etc/mkinitcpio.conf

arch-chroot /mnt mkinitcpio -P


# Create a new user
arch-chroot /mnt useradd -m -G wheel -s /bin/zsh ${username}
echo "$username:$user_passphrase" | arch-chroot /mnt chpasswd


# Disable the root user
arch-chroot /mnt passwd --delete root && passwd --lock root


# Temporarily give passwordless sudo access for the new user to install and use an AUR helper
echo "$username ALL=(ALL:ALL) NOPASSWD: ALL" >> /mnt/etc/sudoers


# Temporarly disable Pacman wrapper so that no warning is issued
mv /mnt/usr/local/bin/pacman /mnt/usr/local/bin/pacman.disable


# Install an AUR helper of your choice
arch-chroot -u $username /mnt -c "mkdir /tmp/paru.$$ && \
                                  cd /tmp/paru.$$ && \
                                  curl "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=paru-bin" -o PKGBUILD && \
                                  makepkg -si --noconfirm"
 

# Bootloader
HOME="/home/${username}" arch-chroot -u $username /mnt /usr/bin/paru --noconfirm -Sy grub-improved-luks2-git

ROOT_UUID=$(blkid -o value -s UUID $root_part)

sed -i "/GRUB_ENABLE_CRYPTODISK=y/s/^#//" /mnt/etc/default/grub
sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.name=${ROOT_UUID}=${luks_label} rd.luks.options=tries=3 root=/dev/mapper/${luks_label} rootflags=subvol=/@ rw rd.luks.key=/.cryptkey/root.key\"|" /mnt/etc/default/grub

arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

chmod 700 /mnt/boot


# Restore Pacman wrapper
mv /mnt/usr/local/bin/pacman.disable /mnt/usr/local/bin/pacman


# Remove passwordless sudo access from the new user
sed -i "/${username} ALL=(ALL:ALL) NOPASSWD: ALL/d" /mnt/etc/sudoers


# Give the new user sudo access
sed -i "/%wheel ALL=(ALL:ALL) ALL/s/^#//" /mnt/etc/sudoers


# Reboot
#reboot
