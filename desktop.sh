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


# Clean the TTY
clear

# Set a bigger font
setfont $console_font

# Unblock all wireless devices
rfkill unblock all

# Internet connection
if ! ping -c 2 archlinux.org > /dev/null; then
    iwctl --passphrase ${wifi_passphrase} \
          station ${wifi_interface} \
          connect ${wifi_ssid} # use 'connect-hidden' for hidden networks
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
echo -n ${luks_passphrase} | cryptsetup -q \
                                        --type luks2 \
                                        --key-size 512 \
                                        --hash sha512 \
                                        --sector-size 4096 \
                                        --use-random \
                                        --key-file - \
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
mount -o noatime,compress=zstd,commit=120,subvol=@snapshots dev/mapper/${luks_label} /mnt/.snapshots
mount -o noatime,compress=no,nodatacow,subvol=@cryptkey dev/mapper/${luks_label} /mnt/.cryptkey
mount -o noatime,compress=no,nodatacow,subvol=@swap /dev/mapper/${luks_label} /mnt/swap

# Format and mount the EFI partition
mkfs.fat -F 32 -n EFI ${efi_part}
mount ${efi_part} /mnt/efi

# Create and activate a swap file based on RAM size
ram_size=$(free -m | awk '/^Mem:/{print $2}')
swap_size=$(( (ram_size + 1023) / 1024 )) # convert to gigabytes and round up
if [ $swap_size -le 8 ]; then
    swap_size=$((swap_size * 2)) # double if the size is less than or equal to 8 gigabytes
fi
btrfs filesystem mkswapfile --size ${swap_size}G --uuid clear /mnt/swap/swapfile
swapon /mnt/swap/swapfile

# Set up mirrors
reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# Enable parallel downloads in Pacman
sed -i "/ParallelDownloads/s/^#//" /etc/pacman.conf

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

# Install essential packages
pacstrap -K /mnt \
    base base-devel \
    linux-lts linux-firmware \
    ${microcode} \
    cryptsetup \
    btrfs-progs btrfs-assistant \
    snapper snap-pac grub-btrfs \
    efibootmgr \
    plymouth \
    networkmanager \
    terminus-font \
    zsh zsh-completions \
    neovim \
    git

# Generate fstab
genfstab -U /mnt > /mnt/etc/fstab

# Remove subvolids from fstab for better Snapper compatibility
sed -i 's/subvolid=.*,//' /mnt/etc/fstab

# Change root into the new system
#arch-chroot /mnt /bin/zsh -e << EOF

# Set timezone based on IP address
arch-chroot /mnt /bin/zsh ln -sf /usr/share/zoneinfo/$(curl https://ipapi.co/timezone) /etc/localtime
arch-chroot /mnt /bin/zsh hwclock --systohc

# Localization
arch-chroot /mnt /bin/zsh sed -i "/en_US.UTF-8/s/^#//" /etc/locale.gen
arch-chroot /mnt /bin/zsh sed -i "/ru_RU.UTF-8/s/^#//" /etc/locale.gen
arch-chroot /mnt /bin/zsh sed -i "/kk_KZ.UTF-8/s/^#//" /etc/locale.gen
arch-chroot /mnt /bin/zsh locale-gen
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf
echo "FONT=${console_font}" > /mnt/etc/vconsole.conf

# Network configuration
echo "${hostname}" > /mnt/etc/hostname

# Initramfs
sed -i "s/MODULES=()/MODULES=(btrfs)/" /mnt/etc/mkinitcpio.conf
sed -i "s/BINARIES=()/BINARIES=(\/usr\/bin\/btrfs)/" /mnt/etc/mkinitcpio.conf
sed -i "s/HOOKS=(.*)/HOOKS=(base systemd plymouth autodetect microcode modconf sd-vconsole block sd-encrypt btrfs filesystems keyboard fsck)/" /mnt/etc/mkinitcpio.conf
arch-chroot /mnt /bin/zsh mkinitcpio -P

# User management
arch-chroot /mnt /bin/zsh useradd -m -G wheel,libvert -s /bin/zsh ${username}
arch-chroot /mnt /bin/zsh echo -n ${user_passphrase} | passwd ${username}
arch-chroot /mnt /bin/zsh passwd --delete root && passwd --lock root # disable the root user
echo "${username} ALL=(ALL:ALL) ALL" > /mnt/etc/sudoers.d/${username}

# Boot loader
arch-chroot /mnt /bin/zsh cd ~ && git clone https://aur.archlinux.org/grub-improved-luks2-git.git # patched GRUB2 with Argon2 support
arch-chroot /mnt /bin/zsh cd grub-improved-luks2-git
arch-chroot /mnt /bin/zsh echo -n ${user_passphrase} | su ${username}
arch-chroot /mnt /bin/zsh echo -n ${user_passphrase} | sudo makepkg -rsi --noconfirm
arch-chroot /mnt /bin/zsh exit
arch-chroot /mnt /bin/zsh cd ~ && rm -rf grub-improved-luks2-git

grub-install --target=x86_64-efi --efi-directory=/mnt/efi --bootloader-id=GRUB

DRIVE_UUID=$(blkid -o value -s UUID ${drive})
ROOT_UUID=$(blkid -o value -s UUID ${root_part})

sed -i "s/#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/" /mnt/etc/default/grub
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=""/GRUB_CMDLINE_LINUX_DEFAULT="rd.luks.name=${DRIVE_UUID}=${luks_label} rd.luks.options=tries=3,discard,no-read-workqueue,no-write-workqueue root=UUID=${ROOT_UUID} rootflags=subvol=/@ rw quiet splash loglevel=3 rd.udev.log_priority=3"/' /mnt/etc/default/grub

grub-mkconfig -o /mnt/boot/grub/grub.cfg

# Mirror setup and Pacman configuration
reflector --latest 10 --protocol https --sort rate --save /mnt/etc/pacman.d/mirrorlist
sed -i "/Color/s/^#//" /mnt/etc/pacman.conf
sed -i "/ParallelDownloads/s/^#//g" /mnt/etc/pacman.conf
sed -i "/ParallelDownloads/ILoveCandy" /mnt/etc/pacman.conf

# Reboot
#exit
#umount -a
#cryptsetup close ${luks_label}
#reboot

#EOF
