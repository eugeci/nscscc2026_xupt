#!/bin/sh
set -eu

ROOTFS=${1:-$HOME/vision-kernel-v02/initrd_d}
STAGE=${2:-.}

test -d "$ROOTFS"
test -f "$STAGE/lcdctl"
test -f "$STAGE/naruto_800x480.rgb565"

install -d "$ROOTFS/vision" "$ROOTFS/usr/bin"
install -m 0755 "$STAGE/lcdctl" "$ROOTFS/vision/lcdctl"
install -m 0644 "$STAGE/naruto_800x480.rgb565" \
    "$ROOTFS/vision/naruto.rgb565"
ln -sfn ../../vision/lcdctl "$ROOTFS/usr/bin/lcdctl"

test "$(wc -c < "$ROOTFS/vision/naruto.rgb565")" -eq 768000
echo "Installed:"
ls -lh "$ROOTFS/vision/lcdctl" "$ROOTFS/vision/naruto.rgb565" \
       "$ROOTFS/usr/bin/lcdctl"
echo "Rebuild the kernel so the updated initramfs is embedded."
