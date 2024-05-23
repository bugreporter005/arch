# -----------------------------------------------
# Encrypted Arch Linux Installation Script
# Last update in May 2024
# https://wiki.archlinux.org/title/Installation_guide
# -----------------------------------------------

#!/bin/bash


console_font="ter-v18n"

wifi_interface="wlan0"
wifi_SSID=""
wifi_passphrase=""

drive="/dev/vda" # run 'fdisk'
efi_partition="${drive}1"
root_partition="${drive}2"

luks_label="cryptroot"
luks_passphrase=""

hostname="arch"
timezone="" # run 'timedatectl list-timezones'
username=""
user_passphrase=""




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
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@swap


# Mount the BTRFS subvolumes 
umount /mnt
mount -o noatime,compress=zstd,commit=120,subvol=@ /dev/mapper/${luks_label} /mnt
mkdir -p /mnt/{boot,efi,home,swap,.snapshots,tmp,var/log,var/cache/pacman/pkg,var/lib/docker}
mount -o subvol=@home /dev/mapper/${luks_label} /mnt/home
mount -o subvol=@tmp /dev/mapper/${luks_label} /mnt/tmp
mount -o subvol=@log /dev/mapper/${luks_label} /mnt/var/log
mount -o subvol=@pkg /dev/mapper/${luks_label} /mnt/var/cache/pacman/pkg
mount -o subvol=@docker /dev/mapper/${luks_label} /mnt/var/lib/docker
mount -o subvol=@snapshots dev/mapper/${luks_label} /mnt/.snapshots
mount -o subvol=@swap /dev/mapper/${luks_label} /mnt/swap


# Format and mount the EFI partition
mkfs.fat -F 32 -n EFI ${efi_partition}
mount ${efi_partition} /mnt/efi


# Swap file (double of the size of memory)
# TODO: Check if it works
RAM=$(free -m | awk '/^Mem:/{print $2}')
btrfs filesystem mkswapfile --size $((RAM * 2))m --uuid clear /mnt/swap/swapfile
swapon /mnt/swap/swapfile


# Set up mirrors
#reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist


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


# Update keyrings to prevent packages failing to install
pacman -Sy archlinux-keyring --noconfirm


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
arch-chroot /mnt


# Set timezone
arch-chroot /mnt timedatectl set-timezone ${timezone}
arch-chroot /mnt hwclock --systohc


# Localization
arch-chroot /mnt sed -i "s/#en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
arch-chroot /mnt sed -i "s/#ru_RU.UTF-8/ru_RU.UTF-8/" /etc/locale.gen
arch-chroot /mnt sed -i "s/#kk_KZ.UTF-8/kk_KZ.UTF-8/" /etc/locale.gen
arch-chroot /mnt locale-gen
arch-chroot /mnt localectl set-locale "LANG=en_US.UTF-8"
arch-chroot /mnt echo "FONT=${console_font}" > /etc/vconsole.conf


# Network configuration
arch-chroot /mnt hostnamectl hostname ${hostname}


# Initramfs
arch-chroot /mnt sed -i "s/MODULES=()/MODULES=(btrfs)/" /etc/mkinitcpio.conf
arch-chroot /mnt sed -i "s/BINARIES=()/BINARIES=(\/usr\/bin\/btrfs)/" /etc/mkinitcpio.conf
arch-chroot /mnt sed -i "s/HOOKS=(.*)/HOOKS=(base systemd plymouth autodetect microcode modconf sd-vconsole block sd-encrypt btrfs filesystems keyboard fsck)/" /etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -p linux


# User management
arch-chroot /mnt useradd -m -G wheel,audio,video -s /bin/zsh ${username}
arch-chroot /mnt echo -n ${user_passphrase} | passwd ${username}
arch-chroot /mnt passwd --lock root
arch-chroot /mnt echo "${username} ALL=(ALL:ALL) ALL" > /etc/sudoers.d/${username}


# Boot loader
arch-chroot /mnt cd ~ && git clone https://aur.archlinux.org/grub-improved-luks2-git.git # patched GRUB2 with Argon2 support
arch-chroot /mnt cd grub-improved-luks2-git && makepkg -rsi --noconfirm
arch-chroot /mnt cd ~ && rm -rf grub-improved-luks2-git

arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB

arch-chroot /mnt DRIVE_UUID=$(blkid -o value -s UUID ${drive})
arch-chroot /mnt ROOT_UUID=$(blkid -o value -s UUID ${root_partition})

arch-chroot /mnt sed -i "s/#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/" /etc/default/grub
arch-chroot /mnt sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=""/GRUB_CMDLINE_LINUX_DEFAULT="rd.luks.name=${DRIVE_UUID}=${luks_label} rd.luks.options=tries=3,discard,no-read-workqueue,no-write-workqueue root=UUID=${ROOT_UUID} rootflags=subvol=/@ rw quiet splash loglevel=3 rd.udev.log_priority=3"/' /etc/default/grub

arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg


# Pacman configuration
arch-chroot /mnt sed -i "s/#Color/Color/" /etc/pacman.conf
arch-chroot /mnt sed -i "s/#ParallelDownloads = 5/ParallelDownloads = 5\nILoveCandy/" /etc/pacman.conf


# Wi-Fi via NetworkManager
#nmcli dev wifi connect ${wifi_SSID} password ${wifi_passphrase} # add 'hidden yes' for hidden networks
arch-chroot /mnt systemctl enable NetworkManager


# Reboot
exit
#cp arch_base_install.sh arch_post_install.sh /mnt/
#umount /mnt
#reboot
