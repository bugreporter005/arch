#!/bin/bash


# ===============================================
# Arch Linux Post-installation Script
# ===============================================

source preinstall.sh
GPU_driver="" # nvidia or mesa


# Wi-Fi via NetworkManager
nmcli dev wifi connect ${wifi_SSID} password ${wifi_passphrase} # add 'hidden yes' for hidden networks
echo -n ${user_passphrase} | sudo systemctl enable NetworkManager --now


# AUR Helper
cd ~ && git clone https://aur.archlinux.org/paru-bin.git
cd ~/paru-bin/
echo -n ${user_passphrase} | sudo makepkg -rsi --noconfirm
cd ~ && rm -Rf ~/paru-bin


# Additional packages
# TODO: Check if paru works with sudo
echo -n ${user_passphrase} | sudo paru --noconfirm -S \
    wget2 \
    curl \
    man \
    htop \
    fastfetch \
    ntfs-3g gvfs-mtp exfat-utils \
    openssh \
    pipewire pipewire-pulse pipewire-alsa pipewire-jack \
    xorg-wayland plasma-desktop sddm konsole dolphin dolphin-plugin kdeconnect kwrite ark breeze-gtk okular spectacle fuse2 \
    emacs-wayland \
    docker \
    flatpak \
    firefox librewolf-bin ungoogled-chromium-bin \
    freetube-bin \
    libreoffice-fresh ttf-ms-win11-auto \
    anki-bin noto-fonts-emoji \
    ffmpeg \
    thubderbird thunderbird-i18n-en-us thunderbird-i18n-ru thunderbird-i18n-kk \
    obs-studio \
    qemu-full virt-manager

# Video driver
if ${GPU_driver} == "nvidia"; then
    echo -n ${user_passphrase} | sudo pacman --noconfirm -S nvidia-lts nvidia-settings nvidia-smi
    #echo " nvidia-drm.modeset=1" >> /boot/loader/entries/arch.conf
    sudo sed -i "s/MODULES=(.*)/MODULES=(btrfs nvidia nvidia_modeset nvidia_uvm nvidia_drm)/" /etc/mkinitcpio.conf
    sudo mkinitcpio -P
else
    echo -n ${user_passphrase} | sudo pacman -S mesa
fi
