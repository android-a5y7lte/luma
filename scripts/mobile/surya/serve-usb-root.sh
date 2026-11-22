#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Stage 2 of the POCO X3 NFC (surya) bring-up, run on the computer: serves
# Luma's generic phone userdata image to the phone over the USB network (NBD),
# so Luma runs on the phone without writing anything to it.
#
# The first run prepares a raw copy of the image in WORKDIR:
#   - the surya kernel's modules (from the build's modules-*.tar.zst);
#   - the phone's firmware, fetched here from sm7150-mainline's
#     firmware-xiaomi-surya (the files firmware.manifest lists; they stay on
#     this computer and are never uploaded by Luma's builds);
#   - the Adreno 618 microcode (qcom/a630_sqe.fw, qcom/a615_gmu.bin) from this
#     computer's linux-firmware when the image lacks it;
#   - NetworkManager told to leave usb0 alone (the root travels over it).
# New files only: nothing the OSTree deployment already has is changed.
#
# Then, on every run, it waits for the phone's USB network interface, gives
# the computer 172.16.42.2 on it and serves the image with qemu-nbd
# (export "luma", port 10809), which the stage 2 boot image connects to.
#
# usage: sudo serve-usb-root.sh USERDATA.simg.zst MODULES.tar.zst [WORKDIR]
#   WORKDIR defaults to ~/luma-surya of the user who ran sudo.
# Needs: zstd, simg2img (android-sdk-libsparse-utils), qemu-nbd (qemu-utils),
# git, losetup, ip.
# To start over from a fresh image, delete WORKDIR/luma-surya-userdata.img.
set -euo pipefail
fail() { printf 'serve-usb-root: %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || fail "run with sudo"
userdata=$(realpath -e "${1:?usage: sudo serve-usb-root.sh USERDATA.simg.zst MODULES.tar.zst [WORKDIR]}")
modules=$(realpath -e "${2:?usage: sudo serve-usb-root.sh USERDATA.simg.zst MODULES.tar.zst [WORKDIR]}")
home=$(getent passwd "${SUDO_USER:-root}" | cut -d: -f6)
work=${3:-$home/luma-surya}
for tool in zstd simg2img qemu-nbd git losetup ip; do
  command -v "$tool" >/dev/null || fail "missing $tool (sudo apt install zstd android-sdk-libsparse-utils qemu-utils git)"
done
mkdir -p "$work"
raw=$work/luma-surya-userdata.img
host_ip=172.16.42.2
mnt=$work/mnt
loop=

cleanup() {
  mountpoint -q "$mnt" && umount "$mnt" || true
  [ -n "$loop" ] && losetup -d "$loop" 2>/dev/null || true
  # A run that stopped half-way may have left the unfinished copy attached.
  for dev in $(losetup -j "$raw.tmp" -O NAME -n 2>/dev/null); do losetup -d "$dev" || true; done
}
cleanup

prepare() {
  echo "Unpacking $(basename "$userdata") (once)..."
  zstd -dc "$userdata" > "$work/userdata.simg"
  simg2img "$work/userdata.simg" "$raw.tmp"
  rm -f "$work/userdata.simg"
  mkdir -p "$mnt"
  loop=$(losetup -b 4096 -fP --show "$raw.tmp")
  trap cleanup EXIT
  mount "${loop}p2" "$mnt"
  local link dep
  link=$(readlink "$mnt/ostree/root.a") || fail "no /ostree/root.a in the image"
  dep=$mnt/ostree/$link
  [ -x "$dep/usr/lib/systemd/systemd" ] || fail "root.a ($link) is not a deployment"
  echo "Deployment: $link"

  echo "Adding the surya kernel modules..."
  tar -C "$dep/usr" -I zstd -xf "$modules" ./lib/modules
  ls "$dep/usr/lib/modules"

  echo "Adding the surya firmware (sm7150-mainline/firmware-xiaomi-surya)..."
  [ -d "$work/firmware-xiaomi-surya/.git" ] ||
    git clone --depth 1 \
      https://github.com/sm7150-mainline/firmware-xiaomi-surya "$work/firmware-xiaomi-surya"
  cp -rn "$work/firmware-xiaomi-surya/usr/lib/firmware/." "$dep/usr/lib/firmware/"
  for fw in qcom/a630_sqe.fw qcom/a615_gmu.bin; do
    ls "$dep/usr/lib/firmware/$fw"* >/dev/null 2>&1 && continue
    if [ -f "/lib/firmware/$fw.zst" ]; then zstd -dcq "/lib/firmware/$fw.zst" > "$dep/usr/lib/firmware/$fw"
    elif [ -f "/lib/firmware/$fw.xz" ]; then xz -dc "/lib/firmware/$fw.xz" > "$dep/usr/lib/firmware/$fw"
    elif [ -f "/lib/firmware/$fw" ]; then cp "/lib/firmware/$fw" "$dep/usr/lib/firmware/$fw"
    else echo "note: $fw not found on this computer; the GPU will not start"; fi
  done

  echo "Keeping NetworkManager off usb0..."
  install -d -m 0755 "$dep/etc/NetworkManager/conf.d"
  printf '# The Luma root comes over usb0 (NBD); do not touch it.\n[keyfile]\nunmanaged-devices=interface-name:usb0\n' \
    > "$dep/etc/NetworkManager/conf.d/90-luma-surya-usb-root.conf"

  sync
  cleanup; trap - EXIT
  mv "$raw.tmp" "$raw"
  echo "Prepared $raw"
}

[ -f "$raw" ] || prepare

echo "Waiting for the phone's USB network (boot the stage 2 image now)..."
while :; do
  iface=$(ip -br link | awk '/^enx/{print $1; exit}')
  [ -n "$iface" ] && break
  sleep 1
done
command -v nmcli >/dev/null && nmcli device set "$iface" managed no 2>/dev/null || true
ip addr replace "$host_ip/24" dev "$iface"
ip link set "$iface" up
echo "Phone on $iface; serving $raw at $host_ip:10809 (Ctrl-C to stop; the phone loses its root)"
exec qemu-nbd --persistent --bind="$host_ip" --port=10809 --export-name=luma \
  --format=raw --cache=writeback --discard=unmap "$raw"
