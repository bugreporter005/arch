#!/bin/bash

# SSDM HiDPI
cat > /etc/sddm.conf.d/hidpi.conf << EOF
[Wayland] 
EnableHiDPI=true 

[X11] 
EnableHiDPI=true

[General]
GreeterEnvironment=QT_SCREEN_SCALE_FACTORS=1.5,QT_FONT_DPI=192
EOF
