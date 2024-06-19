#!/bin/bash


# Exit the script immediately if any command fails
set -e


confirmation() {    
    while true; do
        read -p "$1 [y/n] " answer

        case "$answer" in
            [yY])
                return 0
                ;;
            [nN])
                return 1
                ;;
            *)
            echo "Please enter 'y' or 'n'."
            ;;
        esac
    done
}


selection() {
    while true; do
        read -p "Enter your choice [1/2] " choice

        case "$choice" in
            [1])
                return "1"
                ;;
            [2])
                return "2"
                ;;
            *)
                echo "Please enter 1 or 2."
                ;;
        esac    
    done
}


if ! confirmation "Do you want to proceed with the installation?"; then
    echo "Installation aborted."
    exit 1
fi

option=$(selection "Which installation mode do you want?" "minimal" "full" "")
if [ option == "1" ]; then
    installation_mode="minimal"
else
    installation_mode="full"
fi




# Clean the TTY
clear




# Set a custom TTY font
setfont ter-v18n
echo "Set 'ter-v18n' as a new TTY font."


# Check the OS
if [ ! -e /etc/arch-release ]; then
    echo "This script must be run in Arch Linux!"
    exit 1
fi


# Verify the firmware interface
if [ -d /sys/firmware/efi/efivars ]; then
    firmware="UEFI"
else
    firmware="BIOS"
fi
echo "$firmware mode is detected."


# Check internet connection
echo "Check internet connection..."
ping -c 1 archlinux.org > /dev/null 2>&1
if [ $? -eq 0 ]; then
    echo "Internet connection is up."
else
    echo "Internet connection is down!"
    exit 1
fi


# Update the system clock
timedatectl set-ntp true


# Partition
sgdisk --zap-all $drive
echo "Removed all existing partitions."

if [ $firmware == "UEFI" ]; then
    parted --script $drive \
           mklabel gpt \
           mkpart EFI fat32 0% 301MiB \
           set 1 esp on \
           mkpart root btrfs 301MiB 100% \
           > /dev/null
else
    parted --script $drive \
           mklabel gpt \
           mkpart bios_boot 0% 1MiB \
           set 1 bios_grub on \
           mkpart root btrfs 1MiB 100% \
           > /dev/null
fi
echo "Partitioned '${drive}' with a $firmware layout."


# Encryption
echo -n $luks_passphrase | cryptsetup --type luks2 \
                                      --cipher aes-xts-plain64 \
                                      --pbkdf argon2id \
                                      --key-size 512 \
                                      --hash sha512 \
                                      --sector-size 4096 \
                                      --use-urandom \
                                      --key-file - \
                                      luksFormat ${root_part} \
                                      > /dev/null
echo "Encrypted the root partition."

echo -n $luks_passphrase | cryptsetup --key-file - \
                                      luksOpen ${root_part} ${luks_label} \
                                      > /dev/null
echo "Openned the encrypted root partition."
