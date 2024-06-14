#!/bin/bash


# Clean the TTY
clear


# Set a custom TTY font
setfont ter-v18n
echo "Replace the default TTY font with 'ter-v18n'."


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

if [ $firmware == "UEFI" ]; then
    parted --script $drive \
           mklabel gpt \
           mkpart EFI fat32 0% 301MiB \
           set 1 esp on \
           mkpart root btrfs 301MiB 100%
else
    parted --script $drive \
           mklabel gpt \
           mkpart bios_boot 0% 1MiB \
           set 1 bios_grub on \
           mkpart root btrfs 1MiB 100%
fi
