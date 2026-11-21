#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Bring-up initramfs for surya: static busybox, USB networking (NCM gadget,
# 172.16.42.1, the postmarketOS debug address), a telnet shell and a shell on
# the USB serial port. It never mounts, writes or erases a partition of the
# phone.
#
# Stage 1 (no luma.nbd= argument): stays in the debug shell.
# Stage 2 (luma.nbd=HOST:PORT[:EXPORT]): connects /dev/nbd0 to the computer's
# NBD server over the USB network (scripts/mobile/surya/serve-usb-root.sh),
# mounts LumaRoot (ext4, nbd0p2) of the generic phone userdata image, sets up
# the OSTree deployment that /ostree/root.a points at (what ostree-prepare-root
# does, without composefs) and switches to its systemd. On any failure it
# stays in the debug shell.
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

for applet in nbd-client switch_root mdev telnetd; do
  "$busybox" --list | grep -qx "$applet" || { echo "busybox lacks $applet" >&2; exit 1; }
done

root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
mkdir -p "$root"/{bin,sbin,dev,proc,sys,tmp,run,mnt,etc,lib/modules,sysroot,newroot}
cp "$busybox" "$root/bin/busybox"
# --list includes "busybox" itself: linking it would replace the binary with
# a link to itself (ELOOP, error -40, on the phone).
for applet in $("$busybox" --list); do
  [ "$applet" = busybox ] && continue
  ln -sf busybox "$root/bin/$applet"
done
[ -f "$root/bin/busybox" ] && [ ! -L "$root/bin/busybox" ] || { echo "bin/busybox is not a file" >&2; exit 1; }
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
# telnetd needs pseudo-terminals.
mkdir -p /dev/pts && mount -t devpts -o gid=5,mode=620 devpts /dev/pts
log() { echo "luma-surya: $*" > /dev/kmsg; echo "luma-surya: $*"; }

boot_nbd() {
  host=$(echo "$1" | cut -d: -f1); port=$(echo "$1" | cut -d: -f2)
  name=$(echo "$1" | cut -d: -f3); [ -n "$name" ] || name=luma
  log "stage 2: waiting for the Luma root at $host:$port (export $name)"
  i=0
  until nbd-client -b 4096 -N "$name" "$host" "$port" /dev/nbd0; do
    i=$((i+1))
    [ $i -lt 150 ] || { log "no NBD server after 5 minutes; staying in the debug shell"; return 1; }
    sleep 2
  done
  i=0
  while [ ! -b /dev/nbd0p2 ] && [ $i -lt 50 ]; do mdev -s; sleep 0.2; i=$((i+1)); done
  [ -b /dev/nbd0p2 ] || { log "no LumaRoot partition on /dev/nbd0"; return 1; }
  mkdir -p /sysroot /newroot
  mount -t ext4 -o rw,noatime /dev/nbd0p2 /sysroot || { log "cannot mount LumaRoot"; return 1; }
  link=$(readlink /sysroot/ostree/root.a)
  dep=/sysroot/ostree/$link
  [ -n "$link" ] && [ -x "$dep/usr/lib/systemd/systemd" ] || { log "root.a ($link) is not a deployment"; return 1; }
  log "deployment $link"
  stateroot=$(echo "$link" | cut -d/ -f2)
  mount --bind "$dep" /newroot
  mount --bind /sysroot /newroot/sysroot
  mount --bind "/sysroot/ostree/deploy/$stateroot/var" /newroot/var
  [ -d /newroot/boot ] && mount --bind /sysroot/boot /newroot/boot
  mount --bind /newroot/usr /newroot/usr && mount -o remount,bind,ro /newroot/usr
  : > /run/ostree-booted
  dmesg > /run/luma-surya-initramfs-dmesg.txt
  log "switching to Luma (systemd)"
  for m in run dev proc sys; do mount --move /$m /newroot/$m; done
  exec switch_root /newroot /usr/lib/systemd/systemd
}
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

nbd=$(sed -n 's/.*luma\.nbd=\([^ ]*\).*/\1/p' /proc/cmdline)
[ -n "$nbd" ] && boot_nbd "$nbd"
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
