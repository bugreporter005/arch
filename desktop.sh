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

hostname="archlinux"
username=""
user_passphrase=""


# -------------------------------------------------------------------------------------------------
# Installation
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


# Exit the script immediately if any command fails
set -e


# Clean the TTY
clear


# Verify Arch Linux
if [ ! -e /etc/arch-release ]; then
    echo "This script must be run in Arch Linux!"
    exit 1
fi


# Verify the UEFI mode
if [ ! -d /sys/firmware/efi/efivars ]; then
    echo "System is not booted in the UEFI mode!"
    exit 1
fi


# Verify the status of Secure Boot in BIOS
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

    # Recheck the internet connection
    if [ ! ping -c 1 archlinux.org > /dev/null ]; then
        echo "No internet connection!"
        exit 1
    fi
fi


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
    # Default LUKS2 with Argon2id
    echo -n "$luks_passphrase" | cryptsetup --key-size 512 \
                                            --hash sha512 \
                                            --key-file - \
                                            luksFormat $root_part    
else
    # [⚠️] LUKS1 with PBKDF2 (vulnerable to bruteforcing)
    echo -n "$luks_passphrase" | cryptsetup --type luks1 \
                                            --key-size 512 \
                                            --hash sha512 \
                                            --key-file - \
                                            luksFormat $root_part
fi 

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
btrfs subvolume create /mnt/@home-snapshots
btrfs subvolume create /mnt/@cryptkey


# Disable copy on write for some subvolumes
chattr +C /mnt/@tmp
chattr +C /mnt/@var
chattr +C /mnt/@swap
chattr +C /mnt/@cryptkey


# Mount the BTRFS subvolumes and partitions
umount /mnt

mount -o noatime,compress=zstd,subvol=@     LABEL=root /mnt

mkdir -p /mnt/{efi,home/.snapshots,opt,srv,tmp,var,swap,.snapshots,.cryptkey}

mount -o noatime,subvol=@home               LABEL=root /mnt/home
mount -o noatime,subvol=@opt                LABEL=root /mnt/opt
mount -o noatime,subvol=@srv                LABEL=root /mnt/srv
mount -o noatime,subvol=@snapshots          LABEL=root /mnt/.snapshots
mount -o noatime,subvol=@home-snapshots     LABEL=root /mnt/home/.snapshots
mount -o noatime,nodatacow,subvol=@tmp      LABEL=root /mnt/tmp
mount -o noatime,nodatacow,subvol=@var      LABEL=root /mnt/var
mount -o noatime,nodatacow,subvol=@swap     LABEL=root /mnt/swap
mount -o noatime,nodatacow,subvol=@cryptkey LABEL=root /mnt/.cryptkey

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
    linux-lts $linux_firmware \
    $microcode \
    cryptsetup \
    grub efibootmgr grub-btrfs \
    btrfs-progs snapper snap-pac \
    zram-generator \
    networkmanager \
    reflector \
    terminus-font \
    zsh \
    neovim \
    apparmor


# Prevent Systemd from creating BTRFS subvolumes for 'var/lib/portables' & 'var/lib/machines'
touch /mnt/etc/tmpfiles.d/{portables,systemd-nspawn}.conf


# Generate the fstab & remove subvolid entries to boot into snapshots without errors
genfstab -L /mnt > /mnt/etc/fstab
sed -i 's/subvolid=.*,//' /mnt/etc/fstab


# Set timezone based on IP address
arch-chroot /mnt ln -sf /usr/share/zoneinfo/$(curl https://ipapi.co/timezone) /etc/localtime
arch-chroot /mnt hwclock --systohc
arch-chroot /mnt systemctl enable systemd-timesyncd.service


# Locales
arch-chroot /mnt sed -i "/en_US.UTF-8/s/^#//" /etc/locale.gen
arch-chroot /mnt sed -i "/ru_RU.UTF-8/s/^#//" /etc/locale.gen
arch-chroot /mnt sed -i "/kk_KZ.UTF-8/s/^#//" /etc/locale.gen

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
fi

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
KERNEL_PARAMS="\
rd.luks.name=$(blkid -o value -s UUID $root_part)=cryptroot \
rd.luks.options=tries=3,discard,no-read-workqueue,no-write-workqueue \
root=/dev/mapper/cryptroot \
rootflags=subvol=/@ \
rd.luks.key=/.cryptkey/root.key \
quiet \
rd.udev.log_level=3 \
rd.udev.log_priority=3 \
resume=/dev/mapper/cryptroot \
resume_offset=$(btrfs inspect-internal map-swapfile -r /mnt/swap/swapfile) \
lsm=landlock,lockdown,yama,integrity,apparmor,bpf"

sed -i "/GRUB_ENABLE_CRYPTODISK=y/s/^#//" /mnt/etc/default/grub
sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"$KERNEL_PARAMS\"|" /mnt/etc/default/grub

arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB
arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

chmod 700 /mnt/boot

arch-chroot /mnt systemctl enable grub-btrfsd.service


# Enable Apparmor
arch-chroot /mnt systemctl enable apparmor.service


# Configure ZRAM if the host machine has less than 64GB RAM
if [ $RAM_SIZE -l 64 ]; then
    echo "[zram0]"                      >> /mnt/etc/systemd/zram-generator.conf
    echo "zram-size = ram"              >> /mnt/etc/systemd/zram-generator.conf
    echo "compression-algorithm = zstd" >> /mnt/etc/systemd/zram-generator.conf
    
    arch-chroot /mnt systemctl daemon-reload
    arch-chroot /mnt systemctl start systemd-zram-setup@zram0.service

    sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/"$/ zswap.enabled=0"/' /mnt/etc/default/grub
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

    echo "vm.swappiness = 180"             >> /etc/sysctl.d/99-vm-zram-parameters.conf
    echo "vm.watermark_boost_factor = 0"   >> /etc/sysctl.d/99-vm-zram-parameters.conf
    echo "vm.watermark_scale_factor = 125" >> /etc/sysctl.d/99-vm-zram-parameters.conf
    echo "vm.page-cluster = 0"             >> /etc/sysctl.d/99-vm-zram-parameters.conf
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


# [⚠️] Temporarily give passwordless sudo permission for the new user to install and use an AUR helper
echo "$username ALL=(ALL:ALL) NOPASSWD: ALL" >> /mnt/etc/sudoers


# [⚠️] Install Paru
arch-chroot -u "$username" /mnt bash -c "mkdir /tmp/paru.$$ && \
                                         cd /tmp/paru.$$ && \
                                         curl "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=paru-bin" -o PKGBUILD && \
                                         makepkg -si --noconfirm"


# [⚠️] Install user packages
HOME="/home/${username}" arch-chroot -u "$username" /mnt paru --noconfirm --needed -S \
    stow \
    wget2 \
    curl \
    man-db man-pages \
    htop \
    fastfetch \
    fzf \
    git \
    lsd \
    bat \
    exfatprogs \
    openssh \
    btrfs-assistant \
    tlp tlp-rdw \
    firejail \
    pipewire pipewire-pulse pipewire-alsa pipewire-jack \ 
    ttf-jetbrains-mono-nerd otf-commit-mono-nerd \
    emacs-wayland \
    wl-clipboard \
    zip unzip \    
    docker \
    flatpak flatseal \
    firefox librewolf-bin ungoogled-chromium-bin \
    freetube-bin \
    foliate \
    libreoffice-fresh ttf-ms-win11-auto \
    anki-bin noto-fonts-emoji \
    ffmpeg \
    obs-studio \
    schildichat-desktop-bin \
    thunderbird thunderbird-i18n-en-us thunderbird-i18n-ru thunderbird-i18n-kk \
    qemu-full virt-manager virt-viewer dmidecode libguestfs nftables dnsmasq openbsd-netcat vde2 bridge-utils #\
    #gnome extension-manager

#arch-chroot /mnt flatpak install -y flathub us.zoom.Zoom

arch-chroot /mnt pacman --noconfirm --needed -S plasma --ignore kuserfeedback \
                                                                kwallet kwallet-pam ksshaskpass \
                                                                breeze-plymouth \
                                                                discover \
                                                                oxygen oxygen-sounds


# [⚠️] Remove passwordless sudo permission from the new user
sed -i "/${username} ALL=(ALL:ALL) NOPASSWD: ALL/d" /mnt/etc/sudoers


# Disable KWallet
#cat >> /mnt/home/${username}/.config/kwallet << EOF
#[Wallet]
#Enabled=false
#EOF


# Detect GPU(s) and install video driver(s)
gpu=$(lspci | grep "VGA compatible controller")
if [ grep "Intel" <<< $gpu && grep -E "NVIDIA|GeForce" <<< $gpu ]; then
    gpu_driver="mesa lib32-mesa vulkan-intel lib32-vulkan-intel libva-intel-driver libva-utils nvidia-lts nvidia-settings nvidia-smi"
elif [ grep -E "AMD|Radeon" <<< $gpu && grep -E "NVIDIA|GeForce" <<< $gpu ]; then
    gpu_driver="mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver libva-utils nvidia-lts nvidia-settings nvidia-smi"
elif [ grep "Intel" <<< $gpu ]; then
    gpu_driver="mesa lib32-mesa vulkan-intel lib32-vulkan-intel libva-intel-driver libva-utils"
    sed -i '/^MODULES=/ s/)/ i915&/' /mnt/etc/mkinitcpio.conf
    sed -i '/^HOOKS=/ s/)/ kms&/' /mnt/etc/mkinitcpio.conf
elif [ grep -E "AMD|Radeon" <<< $gpu ]; then
    gpu_driver="mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver libva-utils"
    sed -i '/^MODULES=/ s/)/ amdgpu&/' /mnt/etc/mkinitcpio.conf
    sed -i '/^HOOKS=/ s/)/ kms&/' /mnt/etc/mkinitcpio.conf
elif [ grep -E "NVIDIA|GeForce" <<< $gpu ]; then
    gpu_driver="nvidia-lts nvidia-settings nvidia-smi"
fi

if [ -n $gpu_driver ]; then
    arch-chroot /mnt pacman --noconfirm --needed -S "$gpu_driver"
    
    if [[ *"nvidia"* == $gpu_driver ]]; then
        sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/ s/"$/ nvidia-drm.modeset=1&/' /mnt/etc/default/grub
        arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
        
        sed -i '/^MODULES=/ s/)/ nvidia nvidia_modeset nvidia_uvm nvidia_drm&/' /mnt/etc/mkinitcpio.conf

        cat > /mnt/etc/pacman.d/hooks/nvidia.hook << EOF
[Trigger]
Operation=Install
Operation=Upgrade
Operation=Remove
Type=Package
Target=nvidia-lts
Target=linux-lts

[Action]
Description=Updating NVIDIA module in initcpio
Depends=mkinitcpio
When=PostTransaction
NeedsTargets
Exec=/bin/sh -c 'while read -r trg; do case $trg in linux*) exit 0; esac; done; /usr/bin/mkinitcpio -P'
EOF
    fi
    
    arch-chroot /mnt mkinitcpio -P
fi


# Configure Zsh
touch /mnt/home/${username}/.zshrc

cat > /mnt/home/${username}/.zshrc << EOF
# Simple function to load plugins without a plugin manager
function plugin-load {
  local repo plugdir initfile initfiles=()
  : ${ZPLUGINDIR:=${ZDOTDIR:-~/.config/zsh}/plugins}
  
  for repo in $@; do
    plugdir=$ZPLUGINDIR/${repo:t}
    initfile=$plugdir/${repo:t}.plugin.zsh
    
    if [[ ! -d $plugdir ]]; then
      echo "Cloning $repo..."
      git clone -q --depth 1 --recursive --shallow-submodules \
        https://github.com/$repo $plugdir
    fi
    
    if [[ ! -e $initfile ]]; then
      initfiles=($plugdir/*.{plugin.zsh,zsh-theme,zsh,sh}(N))
      (( $#initfiles )) || { echo >&2 "No init file found '$repo'." && continue }
      ln -sf $initfiles[1] $initfile
    fi
    
    fpath+=$plugdir
    (( $+functions[zsh-defer] )) && zsh-defer . $initfile || . $initfile
  done
}

# Plugin repositories
plugins=(
    romkatv/powerlevel10k
    zsh-users/zsh-completions
    zsh-users/zsh-syntax-highlighting
    zsh-users/zsh-autosuggestions    
)

# Load the plugins above
plugin-load $plugins

# Completions
autoload -Uz compinit
compinit
zstyle ':completion:*' menu select                       # navigate between completions with double Tab and arrow keys
zstyle ':completion::complete:*' gain-privileges 1       # allow sudo completions
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'   # case-insensitive completions
zstyle ':completion:*' list-colors '${(ls.:.)LS_COLORS}' # colorized completions

# History
HISTSIZE=5000
HISTFILE=~/.zsh_history
SAVEHIST=$HISTSIZE
HISTDUP=erase
setopt appendhistory
setopt sharehistory
setopt hist_ignore_space
setopt hist_ignore_all_dups
setopt hist_save_no_dups
setopt hist_ignore_dups
setopt hist_find_no_dups

# Keybindings
bindkey -e                           # Emacs-like keybindings
bindkey '^p' history-search-backward # syntax-sensitive history navigation
bindkey '^n' history-search-forward  # syntax-sensitive history navigation

# Aliases
alias ls="lsd --group-dirs first"
alias cat=bat
EOF


# Configure Libvirt
sed -i "/#unix_sock_group/s/^#//" /mnt/etc/libvirt/libvirtd.conf
sed -i "/#unix_sock_rw_perms/s/^#//" /mnt/etc/libvirt/libvirtd.conf
arch-chroot /mnt usermod -a -G libvirt "$username"
arch-chroot /mnt systemctl enable libvirtd.service


# Configure TLP
sed -i "s|#TLP_DEFAULT_MODE=AC|TLP_DEFAULT_MODE=BAT|" /mnt/etc/tlp.conf
#sed -i "s|#TLP_PERSISTENT_DEFAULT=0|TLP_PERSISTENT_DEFAULT=1|" /mnt/etc/tlp.conf
sed -i "/#RUNTIME_PM_ON_BAT=auto/s/^#//" /mnt/etc/tlp.conf
sed -i "s|#DEVICES_TO_DISABLE_ON_STARTUP=\".*\"|DEVICES_TO_DISABLE_ON_STARTUP=\"bluetooth nfc\"|" /mnt/etc/tlp.conf
sed -i "/#START_CHARGE_THRESH_BAT0=75/s/^#//" /mnt/etc/tlp.conf
sed -i "/#STOP_CHARGE_THRESH_BAT0=80/s/^#//" /mnt/etc/tlp.conf

arch-chroot /mnt systemctl mask systemd-rfkill.service
arch-chroot /mnt systemctl mask systemd-rfkill.socket
arch-chroot /mnt systemctl enable tlp.service


# Enable Systemd services
arch-chroot /mnt systemctl enable sddm.service
#arch-chroot /mnt systemctl enable gdm.service
arch-chroot /mnt systemctl enable docker.service


# Reboot
umount -R /mnt
cryptsetup close cryptroot
reboot
