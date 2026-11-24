#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# Build the RAM-boot U-Boot images for the Xiaomi POCO X3 NFC (surya) from
# sm7150-mainline/u-boot, the tree postmarketOS' releases come from. ABL
# boots u-boot.img as a header v0 image: gzip'd U-Boot with the DTB appended.
#
#   scripts/mobile/surya/build-u-boot.sh OUTDIR
#
# Needs a native or cross aarch64 toolchain (set CROSS_COMPILE) and the C
# mkbootimg from osm0sis/mkbootimg (Ubuntu's Python one needs a gki module).
set -eu
out=${1:?usage: build-u-boot.sh OUTDIR}
repo=${UBOOT_REPO:-https://github.com/sm7150-mainline/u-boot}
commit=${UBOOT_COMMIT:-f8c04469e8284aa2f1691a30aa3b7dc59fa0b8cd}
mkbootimg=${MKBOOTIMG:-mkbootimg}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"; out=$(cd "$out" && pwd)
git init -q "$work/u-boot"
git -C "$work/u-boot" fetch -q --depth 1 "$repo" "$commit"
git -C "$work/u-boot" checkout -q FETCH_HEAD
cd "$work/u-boot"
make O=.output qcom_defconfig qcom-phone.config tauchgang.config
for panel in huaxing tianma; do
  dev=sm7150-xiaomi-surya-$panel
  make O=.output -j"$(nproc)" CONFIG_DEFAULT_DEVICE_TREE=qcom/$dev
  gzip -9n -c .output/u-boot-nodtb.bin > .output/u-boot-nodtb.bin.gz
  cat .output/u-boot-nodtb.bin.gz .output/dts/upstream/src/arm64/qcom/$dev.dtb > .output/uboot-dtb
  "$mkbootimg" --base 0x0 --kernel_offset 0x00008000 --pagesize 4096 \
    --os_version 17.0.0 --os_patch_level 2035-06 \
    --kernel .output/uboot-dtb -o "$out/u-boot-surya-$panel.img"
done
echo "u-boot: $repo @ $commit" > "$out/BUILD-INFO-uboot.txt"
cd "$out" && sha256sum u-boot-surya-*.img
