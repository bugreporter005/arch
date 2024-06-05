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


set -e


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


# Create & enable a swap file for hibernation
RAM_SIZE=$(( ( $(free -m | awk '/^Mem:/{print $2}') + 1023 ) / 1024 ))
btrfs filesystem mkswapfile --size ${RAM_SIZE}G --uuid clear /mnt/swap/swapfile
swapon /mnt/swap/swapfile


# Setup mirrors & enable parallel downloading in Pacman
reflector --latest 5 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

sed -i "/ParallelDownloads/s/^#//g" /etc/pacman.conf
sed -i "s/ParallelDownloads = 5/ParallelDownloads = 5\nDisableDownloadTimeout/" /etc/pacman.conf


# Update keyrings to prevent packages failing to install
pacman -Sy archlinux-keyring --noconfirm


# Skip firmware and microcode installation if running in a virtual machine
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


# Install essential packages
pacstrap -K /mnt \
    base base-devel \
    linux-lts ${linux_firmware} ${microcode} \
    zram-generator \
    cryptsetup \
    btrfs-progs snapper snap-pac \
    plymouth \
    networkmanager \
    reflector \
    terminus-font \
    zsh zsh-completions \
    neovim \
    git


# Generate fstab & remove subvolids to boot into snapshots
genfstab -U /mnt > /mnt/etc/fstab
sed -i 's/subvolid=.*,//' /mnt/etc/fstab


# ZRAM
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


# Network
echo "${hostname}" > /mnt/etc/hostname
ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf
arch-chroot /mnt systemctl enable systemd-resolved.service
arch-chroot /mnt systemctl enable NetworkManager.service


# Backup LUKS header
cryptsetup luksHeaderBackup ${root_part} --header-backup-file /mnt/home/${username}/header.bin


# Initramfs
sed -i "s/MODULES=(.*)/MODULES=(btrfs)/" /mnt/etc/mkinitcpio.conf
sed -i "s/FILES=(.*)/FILES=(\/.cryptkey\/keyfile.bin)/" /mnt/etc/mkinitcpio.conf
sed -i "s/BINARIES=(.*)/BINARIES=(\/usr\/bin\/btrfs)/" /mnt/etc/mkinitcpio.conf
if [ "$microcode" == "" ]; then
    sed -i "s/HOOKS=(.*)/HOOKS=(base systemd plymouth autodetect modconf sd-vconsole block sd-encrypt btrfs filesystems keyboard fsck)/" /mnt/etc/mkinitcpio.conf
else
    sed -i "s/HOOKS=(.*)/HOOKS=(base systemd plymouth autodetect microcode modconf sd-vconsole block sd-encrypt btrfs filesystems keyboard fsck)/" /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -P


# User management
arch-chroot /mnt useradd -m -G wheel -s /bin/zsh ${username}
echo "${username}:${user_passphrase}" | arch-chroot /mnt chpasswd
sed -i "/%wheel ALL=(ALL:ALL) ALL/s/^#//" /mnt/etc/sudoers

arch-chroot /mnt passwd --delete root && passwd --lock root


# Bootloader
ROOT_UUID=$(blkid -o value -s UUID ${root_part})
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /mnt/swap/swapfile)

bootctl install

cat > /mnt/efi/loader/entries/archlinux.conf << EOF
title   Arch Linux
initrd  /initramfs-linux-lts.img
linux   /vmlinuz-linux-lts
options rd.luks.name=${ROOT_UUID}=${luks_label} rd.luks.options=tries=3,discard,no-read-workqueue,no-write-workqueue root=/dev/mapper/${luks_label} rootflags=subvol=/@ rw 
options quiet splash loglevel=3 rd.udev.log_priority=3
options resume=/dev/mapper/${luks_label} resume_offset=${RESUME_OFFSET}
EOF

cat > /mnt/efi/loader/loader.conf << EOF
timeout 3
default archlinux.conf
console-mode max
editor no
EOF


# Pacman configuration
cat > /mnt/etc/xdg/reflector/reflector.conf << EOF
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


# Snapper configuration
umount /mnt/.snapshots
rm -r /mnt/.snapshots

arch-chroot /mnt snapper -c root create-config /
arch-chroot /mnt snapper -c home create-config /home

arch-chroot /mnt btrfs subvolume delete /.snapshots
mkdir /mnt/.snapshots
mount -a

ROOT_SUBVOL_ID=$(arch-chroot /mnt btrfs subvol list / | grep -w 'path @$' | awk '{print $2}')
arch-chroot /mnt btrfs subvol set-default ${ROOT_SUBVOL_ID} /

sed -i "s|ALLOW_GROUPS=\".*\"|ALLOW_GROUPS=\"wheel\"|" /mnt/etc/snapper/configs/root
sed -i "s|TIMELINE_LIMIT_HOURLY=\".*\"|TIMELINE_LIMIT_HOURLY=\"5\"|" /mnt/etc/snapper/configs/root
sed -i "s|TIMELINE_LIMIT_DAILY=\".*\"|TIMELINE_LIMIT_DAILY=\"10\"|" /mnt/etc/snapper/configs/root
sed -i "s|TIMELINE_LIMIT_WEEKLY=\".*\"|TIMELINE_LIMIT_WEEKLY=\"1\"|" /mnt/etc/snapper/configs/root
sed -i "s|TIMELINE_LIMIT_MONTHLY=\".*\"|TIMELINE_LIMIT_MONTHLY=\"0\"|" /mnt/etc/snapper/configs/root
sed -i "s|TIMELINE_LIMIT_YEARLY=\".*\"|TIMELINE_LIMIT_YEARLY=\"0\"|" /mnt/etc/snapper/configs/root

sed -i "s|ALLOW_GROUPS=\".*\"|ALLOW_GROUPS=\"wheel\"|" /mnt/etc/snapper/configs/home
sed -i "s|TIMELINE_LIMIT_HOURLY=\".*\"|TIMELINE_LIMIT_HOURLY=\"5\"|" /mnt/etc/snapper/configs/home
sed -i "s|TIMELINE_LIMIT_DAILY=\".*\"|TIMELINE_LIMIT_DAILY=\"5\"|" /mnt/etc/snapper/configs/home
sed -i "s|TIMELINE_LIMIT_WEEKLY=\".*\"|TIMELINE_LIMIT_WEEKLY=\"1\"|" /mnt/etc/snapper/configs/home
sed -i "s|TIMELINE_LIMIT_MONTHLY=\".*\"|TIMELINE_LIMIT_MONTHLY=\"1\"|" /mnt/etc/snapper/configs/home
sed -i "s|TIMELINE_LIMIT_YEARLY=\".*\"|TIMELINE_LIMIT_YEARLY=\"0\"|" /mnt/etc/snapper/configs/home

arch-chroot /mnt chown -R :wheel /.snapshots/

# Reboot
reboot
