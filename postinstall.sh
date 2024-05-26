#!/bin/bash


source desktop.sh

# Wi-Fi via NetworkManager
nmcli dev wifi connect ${wifi_ssid} \
               password ${wifi_passphrase} # add 'hidden yes' for hidden networks
echo -n ${user_passphrase} | sudo systemctl enable NetworkManager --now

# AUR Helper
cd ~ && git clone https://aur.archlinux.org/paru-bin.git
cd ~/paru-bin/
echo -n ${user_passphrase} | su ${username}
echo -n ${user_passphrase} | sudo makepkg -rsi --noconfirm
exit
cd ~ && rm -Rf ~/paru-bin

# GPU driver
gpu_type=$(lspci)
if grep -E "NVIDIA|GeForce" <<< ${gpu_type}; then
    gpu_driver="nvidia-lts nvidia-settings nvidia-smi"
elif lspci | grep 'VGA' | grep -E "Radeon|AMD"; then
    gpu_driver="mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver libva-utils"
elif grep -E "Integrated Graphics Controller|Intel Corporation UHD" <<< ${gpu_type}; then
    gpu_driver="libva-intel-driver libvdpau-va-gl lib32-vulkan-intel vulkan-intel libva-intel-driver libva-utils lib32-mesa"
fi

# Additional packages
# TODO: Check if paru works with sudo
echo -n ${user_passphrase} | sudo paru --noconfirm -S \
    ${gpu_driver} \
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

# Nvidia settings
# TODO: Fix me
if ${gpu_driver} == "nvidia"; then
    echo -n ${user_passphrase} | sudo pacman --noconfirm -S nvidia-lts nvidia-settings nvidia-smi
    #echo " nvidia-drm.modeset=1" >> /boot/loader/entries/arch.conf
    sudo sed -i "s/MODULES=(.*)/MODULES=(btrfs nvidia nvidia_modeset nvidia_uvm nvidia_drm)/" /etc/mkinitcpio.conf
    sudo mkinitcpio -P
fi
