#!/bin/bash


console_font="ter-v18n"

wifi_interface="wlan0"
wifi_SSID=""
wifi_passphrase=""

drive="/dev/vda" # run 'lsblk'
efi_partition="${drive}1"
root_partition="${drive}2"

luks_label="cryptroot"
luks_passphrase=""

hostname="archlinux"
timezone="" # run 'timedatectl list-timezones'
username=""
user_passphrase=""

GPU_driver="mesa" # 'nvidia' or 'mesa'


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
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@docker
btrfs subvolume create /mnt/@vm
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@swap
btrfs subvolume create /mnt/@cryptkey

# Mount the BTRFS subvolumes 
umount /mnt
mount -o noatime,compress=zstd,commit=120,subvol=@ /dev/mapper/${luks_label} /mnt
mkdir -p /mnt/{boot,efi,home,swap,.snapshots,.cryptkey,tmp,var/log,var/cache/pacman/pkg,var/lib/docker,var/lib/libvirt}
mount -o noatime,compress=zstd,commit=120,subvol=@home /dev/mapper/${luks_label} /mnt/home
mount -o noatime,compress=zstd,commit=120,subvol=@tmp /dev/mapper/${luks_label} /mnt/tmp
mount -o noatime,compress=zstd,commit=120,subvol=@log /dev/mapper/${luks_label} /mnt/var/log
mount -o noatime,compress=zstd,commit=120,subvol=@cache /dev/mapper/${luks_label} /mnt/var/cache
mount -o noatime,compress=zstd,commit=120,subvol=@docker /dev/mapper/${luks_label} /mnt/var/lib/docker
mount -o noatime,compress=zstd,commit=120,subvol=@vm /dev/mapper/${luks_label} /mnt/var/lib/libvirt
mount -o noatime,compress=zstd,commit=120,subvol=@snapshots dev/mapper/${luks_label} /mnt/.snapshots
mount -o noatime,compress=zstd,commit=120,subvol=@cryptkey dev/mapper/${luks_label} /mnt/.cryptkey
mount -o noatime,compress=no,nodatacow,commit=120,subvol=@swap /dev/mapper/${luks_label} /mnt/swap

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

# Detect CPU vendor to install microcode
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
    zsh zsh-completions \
    neovim \
    git

# Generate fstab
genfstab -U /mnt > /mnt/etc/fstab

# Change root into the new system
arch-chroot /mnt /bin/zsh -e << EOF

# Set timezone
ln -sf /usr/share/zoneinfo/${timezone} /mnt/etc/localtime
hwclock --systohc

# Localization
sed -i "s/#en_US.UTF-8/en_US.UTF-8/" /mnt/etc/locale.gen
sed -i "s/#ru_RU.UTF-8/ru_RU.UTF-8/" /mnt/etc/locale.gen
sed -i "s/#kk_KZ.UTF-8/kk_KZ.UTF-8/" /mnt/etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
echo "FONT=${console_font}" > /mnt/etc/vconsole.conf

# Network configuration
echo "${hostname}" > /mnt/etc/hostname

# Initramfs
sed -i "s/MODULES=()/MODULES=(btrfs)/" /mnt/etc/mkinitcpio.conf
sed -i "s/BINARIES=()/BINARIES=(\/usr\/bin\/btrfs)/" /mnt/etc/mkinitcpio.conf
sed -i "s/HOOKS=(.*)/HOOKS=(base systemd plymouth autodetect microcode modconf sd-vconsole block sd-encrypt btrfs filesystems keyboard fsck)/" /mnt/etc/mkinitcpio.conf
mkinitcpio -P

# User management
useradd -m -G wheel,libvert -s /bin/zsh ${username}
echo -n ${user_passphrase} | passwd ${username}
passwd --lock root
echo "${username} ALL=(ALL:ALL) ALL" > /etc/sudoers.d/${username}

# Boot loader
echo -n ${user_passphrase} | su ${username}
cd ~ && git clone https://aur.archlinux.org/grub-improved-luks2-git.git # patched GRUB2 with Argon2 support
cd grub-improved-luks2-git
echo -n ${user_passphrase} | sudo makepkg -rsi --noconfirm
cd ~ && rm -rf grub-improved-luks2-git
exit

grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB

DRIVE_UUID=$(blkid -o value -s UUID ${drive})
ROOT_UUID=$(blkid -o value -s UUID ${root_partition})

sed -i "s/#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/" /mnt/etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=""/GRUB_CMDLINE_LINUX_DEFAULT="rd.luks.name=${DRIVE_UUID}=${luks_label} rd.luks.options=tries=3,discard,no-read-workqueue,no-write-workqueue root=UUID=${ROOT_UUID} rootflags=subvol=/@ rw quiet splash loglevel=3 rd.udev.log_priority=3"/' /mnt/etc/default/grub

grub-mkconfig -o /boot/grub/grub.cfg

# Mirror set up and Pacman configuration
reflector --latest 20 --protocol https --sort rate --save /mnt/etc/pacman.d/mirrorlist
sed -i "s/#Color/Color/" /mnt/etc/pacman.conf
sed -i "s/#ParallelDownloads = 5/ParallelDownloads = 5\nILoveCandy/" /mnt/etc/pacman.conf

# Reboot
exit
#reboot

EOF
