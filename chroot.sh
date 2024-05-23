source preinstall.sh

# Set timezone
ln -sf /usr/share/zoneinfo/${timezone} /etc/localtime
hwclock --systohc


# Localization
sed -i "s/#en_US.UTF-8/en_US.UTF-8/" /etc/locale.gen
sed -i "s/#ru_RU.UTF-8/ru_RU.UTF-8/" /etc/locale.gen
sed -i "s/#kk_KZ.UTF-8/kk_KZ.UTF-8/" /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "FONT=${console_font}" > /etc/vconsole.conf


# Network configuration
echo "${hostname}" > /etc/hostname


# Initramfs
sed -i "s/MODULES=()/MODULES=(btrfs)/" /etc/mkinitcpio.conf
sed -i "s/BINARIES=()/BINARIES=(\/usr\/bin\/btrfs)/" /etc/mkinitcpio.conf
sed -i "s/HOOKS=(.*)/HOOKS=(base systemd plymouth autodetect microcode modconf sd-vconsole block sd-encrypt btrfs filesystems keyboard fsck)/" /etc/mkinitcpio.conf
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
arch-chroot /mn echo -n ${user_passphrase} | sudo makepkg -rsi --noconfirm
cd ~ && rm -rf grub-improved-luks2-git
exit

grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB

DRIVE_UUID=$(blkid -o value -s UUID ${drive})
ROOT_UUID=$(blkid -o value -s UUID ${root_partition})

sed -i "s/#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/" /etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=""/GRUB_CMDLINE_LINUX_DEFAULT="rd.luks.name=${DRIVE_UUID}=${luks_label} rd.luks.options=tries=3,discard,no-read-workqueue,no-write-workqueue root=UUID=${ROOT_UUID} rootflags=subvol=/@ rw quiet splash loglevel=3 rd.udev.log_priority=3"/' /etc/default/grub

grub-mkconfig -o /boot/grub/grub.cfg


# Pacman configuration
sed -i "s/#Color/Color/" /etc/pacman.conf
sed -i "s/#ParallelDownloads = 5/ParallelDownloads = 5\nILoveCandy/" /etc/pacman.conf


# Reboot
exit
#umount /mnt
#reboot
