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
    wifi="yes"
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
                                        --pbkdf pbkdf2 \ # not needed once GRUB 2.13 releases
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
mount -o noatime,compress=zstd,commit=120,subvol=@snapshots /dev/mapper/${luks_label} /mnt/.snapshots
mount -o noatime,compress=no,nodatacow,subvol=@cryptkey /dev/mapper/${luks_label} /mnt/.cryptkey
mount -o noatime,compress=no,nodatacow,subvol=@swap /dev/mapper/${luks_label} /mnt/swap

# Embed a keyfile in initramfs to avoid having to enter the encryption passphrase twice
chmod 700 /mnt/.cryptkey
head -c 64 /dev/urandom > /mnt/.cryptkey/keyfile.bin
chmod 600 /mnt/.cryptkey/keyfile.bin
cryptsetup -v luksAddKey -i 1 ${root_part} /mnt/.cryptkey/keyfile.bin

# Create and activate a swap file based on RAM size
ram_size=$(free -m | awk '/^Mem:/{print $2}')
swap_size=$(( (ram_size + 1023) / 1024 )) # convert to gigabytes and round up
if [ $swap_size -le 8 ]; then
    swap_size=$((swap_size * 2)) # double if the size is less than or equal to 8 gigabytes
fi
btrfs filesystem mkswapfile --size ${swap_size}G --uuid clear /mnt/swap/swapfile
swapon /mnt/swap/swapfile

# Format and mount the EFI partition
mkfs.fat -F 32 -n EFI ${efi_part}
mount ${efi_part} /mnt/efi

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
    grub efibootmgr \
    btrfs-progs snapper snap-pac grub-btrfs \
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

# Initramfs
sed -i "s/MODULES=()/MODULES=(btrfs)/" /mnt/etc/mkinitcpio.conf
sed -i "s/BINARIES=()/BINARIES=(\/usr\/bin\/btrfs)/" /mnt/etc/mkinitcpio.conf
sed -i "s/HOOKS=(.*)/HOOKS=(base systemd plymouth autodetect microcode modconf sd-vconsole block sd-encrypt btrfs filesystems keyboard fsck)/" /mnt/etc/mkinitcpio.conf
arch-chroot /mnt mkinitcpio -P

# User management
arch-chroot /mnt useradd -m -G wheel -s /bin/zsh ${username}
arch-chroot /mnt echo -e "${user_passphrase}\n${user_passphrase}" | passwd ${username}
arch-chroot /mnt passwd --delete root && passwd --lock root # disable the root user
sed -i "/%wheel ALL=(ALL:ALL) ALL/s/^#//" /mnt/etc/sudoers # give the wheel group sudo access

# Boot loader
arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB

DRIVE_UUID=$(blkid -o value -s UUID ${drive})
ROOT_UUID=$(blkid -o value -s UUID ${root_part})

kernel_parameters="
rd.luks.name=${DRIVE_UUID}=${luks_label}
rd.luks.options=tries=3,discard,no-read-workqueue,no-write-workqueue
root=UUID=${ROOT_UUID}
rootflags=subvol=/@ rw
quiet splash
loglevel=3 rd.udev.log_priority=3
"
kernel_parameters="${kernel_parameters//$'\n'/ }" # remove newline characters

sed -i "/GRUB_ENABLE_CRYPTODISK=y/s/^#//" /mnt/etc/default/grub
sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/s/\".*\"/\$kernel_parameters/' /mnt/etc/default/grub

arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

# Mirror setup and Pacman configuration
reflector --latest 10 --protocol https --sort rate --save /mnt/etc/pacman.d/mirrorlist
sed -i "/Color/s/^#//" /mnt/etc/pacman.conf
sed -i "/VerbosePkgLists/s/^#//g" /mnt/etc/pacman.conf
sed -i "/ParallelDownloads/s/^#//g" /mnt/etc/pacman.conf
sed -i "/ParallelDownloads/ILoveCandy" /mnt/etc/pacman.conf

# WiFi connection
if "$wifi" == "yes"; then
    nmcli dev wifi connect ${wifi_ssid} \
                   password ${wifi_passphrase} # add 'hidden yes' for hidden networks
fi
systemctl enable NetworkManager --now

# Reboot
exit
#umount -a
#cryptsetup close ${luks_label}
#reboot
