#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Stage 1 bring-up initramfs for surya: static busybox, USB networking
# (NCM + RNDIS gadget, 172.16.42.1, the postmarketOS debug address) and a
# telnet shell. It proves the kernel, DTB, display and USB come up. It never
# mounts, writes or erases any partition.
#
# usage: build-debug-initramfs.sh KERNEL_OUT_DIR OUTPUT.cpio.gz
# Needs a static aarch64 busybox (BUSYBOX, default /bin/busybox from
# Ubuntu's busybox-static on an arm64 runner), cpio and gzip.
set -euo pipefail
kout=$(realpath -e "${1:?}")
output=$(realpath -m "${2:?}")
busybox=${BUSYBOX:-/bin/busybox}
file "$busybox" | grep -q 'statically linked' || { echo "need a static busybox: $busybox" >&2; exit 1; }
file "$busybox" | grep -q 'aarch64' || { echo "busybox must be aarch64: $busybox" >&2; exit 1; }

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root"/{bin,sbin,dev,proc,sys,tmp,run,mnt,etc,lib/modules}
cp "$busybox" "$root/bin/busybox"
for applet in $("$busybox" --list); do ln -sf busybox "$root/bin/$applet"; done
# USB and display modules, if the config built them as modules.
release=$(cat "$kout/kernelrelease")
if [ -d "$kout/modules/lib/modules/$release" ]; then
  cp -a "$kout/modules/lib/modules/$release" "$root/lib/modules/"
fi
cat > "$root/init" <<'INIT'
#!/bin/sh
export PATH=/bin
mount -t devtmpfs dev /dev 2>/dev/null
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t configfs configfs /sys/kernel/config
mount -t tmpfs tmp /run
log() { echo "luma-surya: $*" > /dev/kmsg; echo "luma-surya: $*"; }
log "stage 1 initramfs, kernel $(uname -r)"
mdev -s 2>/dev/null

# Wait for the USB device controller.
i=0
while [ -z "$(ls /sys/class/udc 2>/dev/null)" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i+1)); done
udc=$(ls /sys/class/udc | head -n1)
g=/sys/kernel/config/usb_gadget/g1
if [ -n "$udc" ] && mkdir -p $g 2>/dev/null; then
  echo 0x18D1 > $g/idVendor; echo 0xD001 > $g/idProduct
  mkdir -p $g/strings/0x409 $g/configs/c.1/strings/0x409
  echo "Luma" > $g/strings/0x409/manufacturer
  echo "POCO X3 NFC (surya) bring-up" > $g/strings/0x409/product
  echo "surya-bringup" > $g/strings/0x409/serialnumber
  echo "NCM+RNDIS" > $g/configs/c.1/strings/0x409/configuration
  mkdir -p $g/functions/ncm.usb0 && ln -s $g/functions/ncm.usb0 $g/configs/c.1/ 2>/dev/null
  mkdir -p $g/functions/acm.usb0 && ln -s $g/functions/acm.usb0 $g/configs/c.1/ 2>/dev/null
  echo "$udc" > $g/UDC
  log "USB gadget on $udc"
else
  log "no USB device controller found"
fi
sleep 1
for ifc in usb0 eth0; do
  if ip link show $ifc >/dev/null 2>&1; then
    ip addr add 172.16.42.1/24 dev $ifc; ip link set $ifc up
    log "network on $ifc: telnet 172.16.42.1"
    break
  fi
done
udhcpd -f /dev/null >/dev/null 2>&1 &
telnetd -l /bin/sh -p 23
[ -e /dev/ttyGS0 ] && setsid sh -c 'exec sh </dev/ttyGS0 >/dev/ttyGS0 2>&1' &

# Show we are alive on the panel's framebuffer console.
for vt in /dev/tty0 /dev/console; do
  [ -w $vt ] && printf '\n\n  Luma on POCO X3 NFC: stage 1\n  kernel %s\n  telnet 172.16.42.1\n' "$(uname -r)" > $vt
done
dmesg > /run/dmesg.txt
log "ready"
while true; do sleep 3600; done
INIT
chmod 755 "$root/init"
cat > "$root/etc/udhcpd.conf" <<'CONF'
start 172.16.42.2
end 172.16.42.254
interface usb0
option subnet 255.255.255.0
CONF
sed -i 's|udhcpd -f /dev/null|udhcpd -f /etc/udhcpd.conf|' "$root/init"
(cd "$root" && find . | sort | cpio -o -H newc --owner 0:0 --quiet | gzip -9n) > "$output"
echo "initramfs -> $output ($(du -h "$output" | cut -f1))"
