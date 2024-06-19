#!/bin/bash


# -------------------------------------------------------------------------------------------------
# Variables
# -------------------------------------------------------------------------------------------------


console_font="ter-v18n"

wifi_interface="wlan0"
wifi_ssid=""
wifi_passphrase=""

drive="/dev/vda" # run 'lsblk'
efi_part="${drive}1" # 'p1' for NVME
root_part="${drive}2"

luks_passphrase=""

locales=(
    # [language code]_[country code].[encoding]
    "en_US.UTF-8"
    "ru_RU.UTF-8"
    "kk_KZ.UTF-8"
)

hostname="archlinux"
username=""
user_passphrase=""


# -------------------------------------------------------------------------------------------------
# Functions
# -------------------------------------------------------------------------------------------------


get_pkg_version() {
    pkg_version=$(pacman -Si $1 | awk '/^Version/{print $3}')

    # Remove everything before ":" if ":" exists
    if [[ "$pkg_version" == *":"* ]]; then
        pkg_version=$(echo "$pkg_version" | sed 's/^[^:]*://')
    fi

    # Remove everything after "-" if "-" exists
    if [[ "$pkg_version" == *"-"* ]]; then
        pkg_version=$(echo "$pkg_version" | sed 's/-.*$//')
    fi

    echo "$pkg_version"
}


# -------------------------------------------------------------------------------------------------
# Pre-installation
# -------------------------------------------------------------------------------------------------


# Exit the script immediately if any command fails
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


# Check if Secure Boot is enabled in BIOS
#setup_mode=$(bootctl status | grep -E "Secure Boot.*setup" | wc -l)
#if [ $setup_mode -ne 1 ]; then
#    echo "The firmware is not in the setup mode. Please check BIOS."
#    exit 1
#fi


# Set a custom TTY font
setfont $console_font


# Check internet connection
if [ ! ping -c 1 archlinux.org > /dev/null ]; then
    # Unlock all wireless devices
    rfkill unblock all    

    # Connect to the WIFI network
    iwctl --passphrase $wifi_passphrase \
          station $wifi_interface \
          connect $wifi_ssid # use 'connect-hidden' for hidden networks
    wifi=1    

    # Recheck the internet connection
    if [ ! ping -c 1 archlinux.org > /dev/null ]; then
        echo "No internet connection!"
        exit 1
    fi
fi


# -------------------------------------------------------------------------------------------------
# Installation
# -------------------------------------------------------------------------------------------------


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
grub_version=$(get_pkg_version "grub")
if (( $(echo "$grub_version >= 2.13" | bc) )); then
    # LUKS2 with Argon2id
    echo -n "$luks_passphrase" | cryptsetup --type luks2 \
                                            --cipher aes-xts-plain64 \
                                            --pbkdf argon2id \
                                            --key-size 512 \
                                            --hash sha512 \
                                            --sector-size 4096 \
                                            --use-urandom \
                                            --key-file - \
                                            luksFormat $root_part    
else
    # LUKS1 with PBKDF2 (easily bruteforceable)
    echo -n "$luks_passphrase" | cryptsetup --type luks1 \
                                            --cipher aes-xts-plain64 \
                                            --pbkdf pbkdf2 \
                                            --key-size 512 \
                                            --hash sha512 \
                                            --use-urandom \
                                            --key-file - \
                                            luksFormat $root_part
fi 

# Open the LUKS container
echo -n "$luks_passphrase" | cryptsetup --key-file - \
                                        luksOpen $root_part cryptroot


# Create filesystems
mkfs.fat -F 32 -n EFI $efi_part
mkfs.btrfs -L root /dev/mapper/cryptroot


# Configure BTRFS subvolumes
mount LABEL=root /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@opt
btrfs subvolume create /mnt/@srv
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@swap
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@home_snapshots
btrfs subvolume create /mnt/@cryptkey


# Disable CoW for temporary files, swap and LUKS keyfile
chattr +C /mnt/@tmp
chattr +C /mnt/@swap
chattr +C /mnt/@cryptkey


# Mount the BTRFS subvolumes and partitions
umount /mnt

mount -o noatime,compress=zstd,commit=60,subvol=@               LABEL=root /mnt

mkdir -p /mnt/{efi,home/.snapshots,opt,srv,tmp,var,swap,.snapshots,.cryptkey}

mount -o noatime,compress=zstd,commit=60,subvol=@home           LABEL=root /mnt/home
mount -o noatime,compress=zstd,commit=60,subvol=@opt            LABEL=root /mnt/opt
mount -o noatime,compress=zstd,commit=60,subvol=@srv            LABEL=root /mnt/srv
mount -o noatime,compress=zstd,commit=60,subvol=@var            LABEL=root /mnt/var
mount -o noatime,compress=zstd,commit=60,subvol=@snapshots      LABEL=root /mnt/.snapshots
mount -o noatime,compress=zstd,commit=60,subvol=@home_snapshots LABEL=root /mnt/home/.snapshots
mount -o noatime,nodatacow,commit=60,subvol=@tmp                LABEL=root /mnt/tmp
mount -o noatime,nodatacow,commit=60,subvol=@swap               LABEL=root /mnt/swap
mount -o noatime,nodatacow,commit=60,subvol=@cryptkey           LABEL=root /mnt/.cryptkey

mount LABEL=EFI /mnt/efi


# Create & enable a swap file for hibernation
RAM_SIZE=$(( ( $(free -m | awk '/^Mem:/{print $2}') + 1023 ) / 1024 ))
btrfs filesystem mkswapfile --size ${RAM_SIZE}G --uuid clear /mnt/swap/swapfile
swapon /mnt/swap/swapfile


# Setup mirrors
reflector --latest 10 \
          --age 12 \
          --protocol https \
          --sort rate \
          --save /etc/pacman.d/mirrorlist


# Enable parallel downloading & disable download timeout in Pacman
sed -i "/ParallelDownloads/s/^#//g" /etc/pacman.conf
sed -i "s/ParallelDownloads = 5/ParallelDownloads = 5\nDisableDownloadTimeout/" /etc/pacman.conf


# Update keyrings to prevent packages failing to install
pacman -Sy --needed --noconfirm archlinux-keyring


# Skip firmware and microcode installation if running in a virtual machine
if [ systemd-detect-virt == "none" ]; then
    # Detect CPU vendor to determine the microcode
    cpu_vendor=$(lscpu | awk '/^Vendor ID/{print $3}')
    if [ "$cpu_vendor" == "AuthenticAMD" ]; then
        cpu_vendor="amd"
    elif [ "$cpu_vendor" == "GenuineIntel" ]; then
        cpu_vendor="intel"
    else
        echo "Unsupported vendor ${cpu_vendor}!"
        exit 1
    fi

    microcode="${cpu_vendor}-ucode"
    linux_firmware="linux-firmware"
else
    microcode=""
    linux_firmware=""
fi


# Install essential packages
pacstrap -K /mnt \
    base base-devel \
    linux-lts $linux_firmware $microcode \
    zram-generator \
    cryptsetup \
    grub efibootmgr grub-btrfs \
    btrfs-progs snapper snap-pac \
    networkmanager \
    reflector \
    terminus-font \
    zsh zsh-completions \
    neovim \
    apparmor


# Prevent Systemd from creating the undesired BTRFS subvolumes
# var/lib/portables is used by 'systemd-portabled' & 'portablectl'
# var/lib/machines is used by 'systemd-nspawn' & 'machinectl'
touch /mnt/etc/tmpfiles.d/{portables,systemd-nspawn}.conf


# Generate the fstab & remove subvolid entries to boot into snapshots without errors
genfstab -L /mnt > /mnt/etc/fstab
sed -i 's/subvolid=.*,//' /mnt/etc/fstab


# Set timezone based on IP address
arch-chroot /mnt ln -sf /usr/share/zoneinfo/$(curl https://ipapi.co/timezone) /etc/localtime
arch-chroot /mnt hwclock --systohc


# Locales
for locale in "${locales[@]}"; do
    arch-chroot /mnt sed -i "/#${locale}/s/^#//" /etc/locale.gen
done
 
arch-chroot /mnt locale-gen

cat > /mnt/etc/locale.conf << EOF
LANG=en_US.UTF-8
LC_MEASUREMENT=en_GB.UTF-8
EOF

echo "FONT=${console_font}" > /mnt/etc/vconsole.conf


# Network
echo $hostname > /mnt/etc/hostname

ln -sf /run/systemd/resolve/stub-resolv.conf /mnt/etc/resolv.conf

arch-chroot /mnt systemctl enable systemd-resolved.service
arch-chroot /mnt systemctl enable NetworkManager.service


# Backup the LUKS header just in case
cryptsetup luksHeaderBackup $root_part --header-backup-file /mnt/home/${username}/root.img


# Add a LUKS keyfile to avoid having to enter the encryption passphrase twice
chmod 700 /mnt/.cryptkey
head -c 64 /dev/urandom > /mnt/.cryptkey/root.key
chmod 000 /mnt/.cryptkey/root.key

echo -n "$luks_passphrase" | cryptsetup luksAddKey $root_part /mnt/.cryptkey/root.key


# Initramfs
sed -i "s|MODULES=(.*)|MODULES=(btrfs)|" /mnt/etc/mkinitcpio.conf
sed -i "s|FILES=(.*)|FILES=(\/.cryptkey\/root.key)|" /mnt/etc/mkinitcpio.conf
sed -i "s|BINARIES=(.*)|BINARIES=(\/usr\/bin\/btrfs)|" /mnt/etc/mkinitcpio.conf
if [ -n $microcode ]; then
    sed -i "s|HOOKS=(.*)|HOOKS=(base systemd autodetect microcode modconf sd-vconsole block sd-encrypt btrfs filesystems keyboard fsck)|" /mnt/etc/mkinitcpio.conf
else
    sed -i "s|HOOKS=(.*)|HOOKS=(base systemd autodetect modconf sd-vconsole block sd-encrypt btrfs filesystems keyboard fsck)|" /mnt/etc/mkinitcpio.conf

arch-chroot /mnt mkinitcpio -P


# Create a new user and give it sudo permission
arch-chroot /mnt useradd -m -G wheel -s /bin/zsh ${username}
echo "$username:$user_passphrase" | arch-chroot /mnt chpasswd
sed -i "/%wheel ALL=(ALL:ALL) ALL/s/^#//" /mnt/etc/sudoers


# Disable the root user
arch-chroot /mnt passwd --delete root && passwd --lock root


# Configure Snapper 
umount /mnt/.snapshots
rm -r /mnt/.snapshots

arch-chroot /mnt snapper -c root create-config /
arch-chroot /mnt snapper -c home create-config /home

arch-chroot /mnt btrfs subvolume delete /.snapshots
mkdir /mnt/.snapshots
arch-chroot /mnt mount -a

ROOT_SUBVOL_ID=$(arch-chroot /mnt btrfs subvol list / | grep -w 'path @$' | awk '{print $2}')
arch-chroot /mnt btrfs subvol set-default $ROOT_SUBVOL_ID /

sed -i "s|ALLOW_GROUPS=\".*\"|ALLOW_GROUPS=\"wheel\"|" /mnt/etc/snapper/configs/root
sed -i "s|TIMELINE_LIMIT_HOURLY=\".*\"|TIMELINE_LIMIT_HOURLY=\"10\"|" /mnt/etc/snapper/configs/root
sed -i "s|TIMELINE_LIMIT_DAILY=\".*\"|TIMELINE_LIMIT_DAILY=\"7\"|" /mnt/etc/snapper/configs/root
sed -i "s|TIMELINE_LIMIT_WEEKLY=\".*\"|TIMELINE_LIMIT_WEEKLY=\"1\"|" /mnt/etc/snapper/configs/root
sed -i "s|TIMELINE_LIMIT_MONTHLY=\".*\"|TIMELINE_LIMIT_MONTHLY=\"0\"|" /mnt/etc/snapper/configs/root
sed -i "s|TIMELINE_LIMIT_YEARLY=\".*\"|TIMELINE_LIMIT_YEARLY=\"0\"|" /mnt/etc/snapper/configs/root

sed -i "s|ALLOW_GROUPS=\".*\"|ALLOW_GROUPS=\"wheel\"|" /mnt/etc/snapper/configs/home
sed -i "s|TIMELINE_LIMIT_HOURLY=\".*\"|TIMELINE_LIMIT_HOURLY=\"6\"|" /mnt/etc/snapper/configs/home
sed -i "s|TIMELINE_LIMIT_DAILY=\".*\"|TIMELINE_LIMIT_DAILY=\"7\"|" /mnt/etc/snapper/configs/home
sed -i "s|TIMELINE_LIMIT_WEEKLY=\".*\"|TIMELINE_LIMIT_WEEKLY=\"0\"|" /mnt/etc/snapper/configs/home
sed -i "s|TIMELINE_LIMIT_MONTHLY=\".*\"|TIMELINE_LIMIT_MONTHLY=\"0\"|" /mnt/etc/snapper/configs/home
sed -i "s|TIMELINE_LIMIT_YEARLY=\".*\"|TIMELINE_LIMIT_YEARLY=\"0\"|" /mnt/etc/snapper/configs/home

arch-chroot /mnt chown -R :wheel /.snapshots/
arch-chroot /mnt chown -R :wheel /home/.snapshots/

arch-chroot /mnt systemctl enable snapper-timeline.timer
arch-chroot /mnt systemctl enable snapper-cleanup.timer


# Bootloader
ROOT_UUID=$(blkid -o value -s UUID $root_part)
RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r /mnt/swap/swapfile)

KERNEL_PARAMS="\
rd.luks.name=${ROOT_UUID}=cryptroot \
rd.luks.options=tries=3,discard,no-read-workqueue,no-write-workqueue \
root=/dev/mapper/cryptroot \
rootflags=subvol=/@ \
rd.luks.key=/.cryptkey/root.key \
loglevel=3 \
rd.udev.log_priority=3 \
resume=/dev/mapper/cryptroot \
resume_offset=${RESUME_OFFSET} \
lsm=landlock,lockdown,yama,integrity,apparmor,bpf"

sed -i "/GRUB_ENABLE_CRYPTODISK=y/s/^#//" /mnt/etc/default/grub
sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"$KERNEL_PARAMS\"|" /mnt/etc/default/grub

arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

chmod 700 /mnt/boot

arch-chroot /mnt systemctl enable grub-btrfsd.service


# Enable Apparmor
arch-chroot /mnt systemctl enable apparmor.service


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


# OOM daemon
arch-chroot /mnt systemctl enable systemd-oomd.service


# Automate mirror update
cat > /mnt/etc/xdg/reflector/reflector.conf << EOF
--latest 10
--age 12
--protocol https
--sort rate
--save /etc/pacman.d/mirrorlist
EOF

arch-chroot /mnt systemctl enable reflector.service


# Configure Pacman
sed -i "/Color/s/^#//" /mnt/etc/pacman.conf
sed -i "/VerbosePkgLists/s/^#//g" /mnt/etc/pacman.conf
sed -i "/ParallelDownloads/s/^#//g" /mnt/etc/pacman.conf
sed -i "s|ParallelDownloads = 5|ParallelDownloads = 5\nILoveCandy|" /mnt/etc/pacman.conf


# -------------------------------------------------------------------------------------------------
# Post-installation
# -------------------------------------------------------------------------------------------------


# [⚠️] Temporarily give passwordless sudo permission for the new user to install and use an AUR helper
echo "$username ALL=(ALL:ALL) NOPASSWD: ALL" >> /mnt/etc/sudoers


# [⚠️] Install Paru
arch-chroot -u $username /mnt /bin/zsh -c "mkdir /tmp/paru.$$ && \
                                           cd /tmp/paru.$$ && \
                                           curl "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=paru-bin" -o PKGBUILD && \
                                           makepkg -si --noconfirm"


# [⚠️] Install user packages
HOME="/home/${username}" arch-chroot -u $username /mnt /usr/bin/paru --noconfirm --needed -S \
    git \
    stow \
    wget2 \
    curl \
    man-db man-pages \
    htop \
    fastfetch \
    lsd \
    bat \
    exfatprogs \
    openssh \
    btrfs-assistant \
    tlp tlp-rdw \
    firejail \
    pipewire pipewire-pulse pipewire-alsa pipewire-jack \ 
    emacs-wayland \
    wl-clipboard \
    fzf \
    zip unzip \    
    docker \
    flatpak flatseal \
    firefox librewolf-bin ungoogled-chromium-bin \
    freetube-bin \
    foliate \
    libreoffice-fresh ttf-ms-win11-auto \
    ttf-jetbrains-mono-nerd \
    anki-bin noto-fonts-emoji \
    ffmpeg \
    obs-studio \
    schildichat-desktop-bin \
    thunderbird thunderbird-i18n-en-us thunderbird-i18n-ru thunderbird-i18n-kk \
    qemu-full virt-manager virt-viewer dmidecode libguestfs nftables dnsmasq openbsd-netcat vde2 bridge-utils \

arch-chroot /mnt pacman --noconfirm --needed -S plasma --ignore kuserfeedback \
                                                                kwallet kwallet-pam ksshaskpass \
                                                                breeze-plymouth \
                                                                discover \
                                                                oxygen oxygen-sounds

#arch-chroot /mnt flatpak install -y flathub us.zoom.Zoom


# [⚠️] Detect GPU(s) and install video driver(s)
gpu=$(lspci | grep "VGA compatible controller")
if [ grep "Intel" <<< ${gpu} && grep -E "NVIDIA|GeForce" <<< ${gpu} ]; then
    gpu_driver="mesa lib32-mesa vulkan-intel lib32-vulkan-intel libva-intel-driver libva-utils nvidia-lts nvidia-settings nvidia-smi"
elif [ grep -E "AMD|Radeon" <<< ${gpu} && grep -E "NVIDIA|GeForce" <<< ${gpu} ]; then
    gpu_driver="mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver libva-utils nvidia-lts nvidia-settings nvidia-smi"
elif [ grep "Intel" <<< ${gpu} ]; then
    gpu_driver="mesa lib32-mesa vulkan-intel lib32-vulkan-intel libva-intel-driver libva-utils"
elif [ grep -E "AMD|Radeon" <<< ${gpu} ]; then
    gpu_driver="mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver libva-utils"
elif [ grep -E "NVIDIA|GeForce" <<< ${gpu} ]; then
    gpu_driver="nvidia-lts nvidia-settings nvidia-smi"
fi

if [ -n $gpu_driver ]; then
    arch-chroot /mnt pacman --noconfirm --needed -S "$gpu_driver"
fi


# [⚠️] Remove passwordless sudo permission from the new user
sed -i "/${username} ALL=(ALL:ALL) NOPASSWD: ALL/d" /mnt/etc/sudoers


# Configure Libvirt
sed -i "/#unix_sock_group/s/^#//" /mnt/etc/libvirt/libvirtd.conf
sed -i "/#unix_sock_rw_perms/s/^#//" /mnt/etc/libvirt/libvirtd.conf
arch-chroot /mnt systemctl enable libvirtd.service
usermod -a -G libvirt $username


# Configure TLP
#sed -i "" /etc/tlp.conf
arch-chroot /mnt systemctl enable tlp.service


# Enable the display manager
arch-chroot /mnt systemctl enable sddm.service


# Reboot
umount -R /mnt
cryptsetup close cryptroot
reboot
