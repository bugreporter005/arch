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

hostname="arch"

username=""
user_passphrase=""

gpu_driver="" # 'nvidia' or 'mesa'


# ---------------------------------------------
# Installation
# ---------------------------------------------

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
    wifi=1
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
btrfs subvolume create /mnt/@cryptkey
btrfs subvolume create /mnt/@swap

# Disable CoW on certain subvolumes
chattr +C /mnt/@tmp
chattr +C /mnt/@cryptkey
chattr +C /mnt/@swap

# Mount the BTRFS subvolumes 
umount /mnt
mount -o noatime,compress=zstd,commit=120,subvol=@ /dev/mapper/${luks_label} /mnt
mkdir /mnt/{boot,efi,home,opt,srv,tmp,var,swap,.snapshots,.cryptkey}
mount -o noatime,compress=zstd,commit=120,subvol=@home /dev/mapper/${luks_label} /mnt/home
mount -o noatime,compress=zstd,commit=120,subvol=@opt /dev/mapper/${luks_label} /mnt/opt
mount -o noatime,compress=zstd,commit=120,subvol=@srv /dev/mapper/${luks_label} /mnt/srv
mount -o noatime,compress=no,nodatacow,subvol=@tmp /dev/mapper/${luks_label} /mnt/tmp
mount -o noatime,compress=zstd,commit=120,subvol=@var /dev/mapper/${luks_label} /mnt/var
mount -o noatime,compress=zstd,commit=120,subvol=@snapshots /dev/mapper/${luks_label} /mnt/.snapshots
mount -o noatime,compress=no,nodatacow,subvol=@cryptkey /dev/mapper/${luks_label} /mnt/.cryptkey
mount -o noatime,compress=no,nodatacow,subvol=@swap /dev/mapper/${luks_label} /mnt/swap

# Swap file configuration and hibernation
ram_size=$(( ( $(free -m | awk '/^Mem:/{print $2}') + 1023 ) / 1024 ))
btrfs filesystem mkswapfile --size ${ram_size}G --uuid clear /mnt/swap/swapfile
swapon /mnt/swap/swapfile
resume_offset=$(btrfs inspect-internal map-swapfile -r /mnt/swap/swapfile)

# Format and mount the EFI partition
mkfs.fat -F 32 -n EFI ${efi_part}
mount ${efi_part} /mnt/efi

# Mirror setup and enable parallel download in Pacman
reflector --latest 5 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
sed -i "/ParallelDownloads/s/^#//g" /etc/pacman.conf

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
    linux_firmware=""
    microcode=""
fi

# Installation of essential packages
pacstrap -K /mnt \
    base base-devel \
    linux-lts ${linux_firmware} ${microcode} \
    zram-generator \
    cryptsetup \
    refind \
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

# Remove subvolids for better Snapper compatibility
sed -i 's/subvolid=.*,//' /mnt/etc/fstab

# Embed a keyfile in initramfs to avoid having to enter the encryption passphrase twice
chmod 700 /mnt/.cryptkey
head -c 64 /dev/urandom > /mnt/.cryptkey/keyfile.bin
chmod 600 /mnt/.cryptkey/keyfile.bin
echo -n ${luks_passphrase} | cryptsetup -v luksAddKey -i 1 ${root_part} /mnt/.cryptkey/keyfile.bin

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
arch-chroot /mnt systemctl enable NetworkManager.service
if [ -n $wifi ]; then
    arch-chroot /mnt nmcli dev wifi connect ${wifi_ssid} \
                                    password ${wifi_passphrase} 
                                    # add 'hidden yes' for hidden networks
fi

# Initramfs
sed -i "s/MODULES=(.*)/MODULES=(btrfs)/" /mnt/etc/mkinitcpio.conf
sed -i "s/FILES=(.*)/FILES=(\/.cryptkey\/keyfile.bin)/" /mnt/etc/mkinitcpio.conf
sed -i "s/BINARIES=(.*)/BINARIES=(\/usr\/bin\/btrfs)/" /mnt/etc/mkinitcpio.conf
sed -i "s/HOOKS=(.*)/HOOKS=(base systemd plymouth autodetect microcode modconf sd-vconsole block sd-encrypt btrfs filesystems keyboard fsck)/" /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -P

# User management
arch-chroot /mnt useradd -m -G wheel -s /bin/zsh ${username}
echo "${username}:${user_passphrase}" | arch-chroot /mnt chpasswd
arch-chroot /mnt passwd --delete root && passwd --lock root # disable the root user
echo "${username} ALL=(ALL:ALL) NOPASSWD: ALL" >> /mnt/etc/sudoers # temporary passwordless sudo access for the new user

# Bootloader
arch-chroot /mnt refind-install
arch-chroot /mnt git clone https://aur.archlinux.org/refind-btrfs.git
arch-chroot /mnt cd refind-btrfs
arch-chroot /mnt sudo -u ${username} makepkg -si --noconfirm && rm -rf $(pwd) && cd -
ROOT_UUID=$(blkid -o value -s UUID ${root_part})
#arch-chroot /mnt echo "MY CONFIG GOES HERE" >> /efi/EFI/refind/refind.conf
#sed -i "/GRUB_ENABLE_CRYPTODISK=y/s/^#//" /mnt/etc/default/grub
#sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.name=${ROOT_UUID}=${luks_label} rd.luks.options=tries=3,discard,no-read-workqueue,no-write-workqueue root=/dev/mapper/${luks_label} rootflags=subvol=/@ rw cryptkey=rootfs:/.cryptkey/keyfile.bin quiet splash loglevel=3 rd.udev.log_priority=3 resume=/dev/mapper/${luks_label} resume_offset=${resume_offset}\"|" /mnt/etc/default/grub
arch-chroot /mnt systemctl enable refind-btrfs.service

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
sed -i "/ParallelDownloads/ILoveCandy" /mnt/etc/pacman.conf


# ---------------------------------------------
# Post-installation
# ---------------------------------------------

# AUR helper
arch-chroot /mnt git clone https://aur.archlinux.org/paru-bin.git
arch-chroot /mnt cd paru-bin
arch-chroot /mnt sudo -u ${username} makepkg -si --noconfirm && rm -rf $(pwd) && cd -

# User packages
arch-chroot /mnt sudo -u ${username} paru --noconfirm -S \
    wget \
    curl \
    man-db man-pages \
    htop \
    fastfetch \
    lsd \
    bat \
    exfatprogs \
    openssh \
    btrfs-assistant \
    pipewire pipewire-pulse pipewire-alsa pipewire-jack \
    xorg-wayland \
    plasma-desktop sddm konsole dolphin dolphin-plugin kdeconnect kwrite ark breeze-gtk okular spectacle fuse2 \
    emacs-wayland \
    docker \
    flatpak \
    firefox librewolf-bin ungoogled-chromium-bin \
    freetube-bin \
    libreoffice-fresh ttf-ms-win11-auto \
    ttf-hack-nerd \
    anki-bin noto-fonts-emoji \
    ffmpeg \
    obs-studio \
    thubderbird thunderbird-i18n-en-us thunderbird-i18n-ru thunderbird-i18n-kk \
    qemu-full virt-manager

# GPU driver detection and installation
gpu_type=$(lspci)
if grep -E "NVIDIA|GeForce" <<< ${gpu_type}; then
    gpu_driver="nvidia-lts nvidia-settings nvidia-smi"
elif lspci | grep 'VGA' | grep -E "Radeon|AMD"; then
    gpu_driver="mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver libva-utils"
elif grep -E "Integrated Graphics Controller|Intel Corporation UHD" <<< ${gpu_type}; then
    gpu_driver="mesa lib32-mesa vulkan-intel lib32-vulkan-intel libva-intel-driver libva-utils"
fi
if [ -n $gpu_driver ] then;
    arch-chroot /mnt pacman -S ${gpu_driver} --noconfirm
fi

# Additional configuration with dotfiles
#arch-chroot /mnt git clone https://github.com/bugreporter005/dotfiles.git
#arch-chroot /mnt cd dotfiles
#arch-chroot /mnt cp zsh/config.cfg > /etc/zsh/
# alias cat=bat && alias ls="lsd --group-dirs first"


# ---------------------------------------------
# Correct user privileges and reboot the system
# ---------------------------------------------

sed -i "/${username} ALL=(ALL:ALL) NOPASSWD: ALL/d" /mnt/etc/sudoers # prohibit the user to passwordlessly access sudo
sed -i "/%wheel ALL=(ALL:ALL) ALL/s/^#//" /mnt/etc/sudoers # give the wheel group sudo access
umount -a
cryptsetup close ${luks_label}
reboot
