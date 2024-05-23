console_font="ter-v18n"

wifi_interface="wlan0"
wifi_SSID=""
wifi_passphrase=""

drive="/dev/vda" # run 'lsblk'
efi_partition="${drive}1"
root_partition="${drive}2"

luks_label="cryptroot"
luks_passphrase=""

hostname="archlinux"
timezone="" # run 'timedatectl list-timezones'
username=""
user_passphrase=""

GPU_driver="" # 'nvidia' or 'mesa'
