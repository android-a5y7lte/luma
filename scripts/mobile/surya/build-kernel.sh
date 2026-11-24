#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Builds the surya bring-up kernel: Image.gz, the Huaxing and Tianma DTBs,
# modules and the final .config.
#
# Until the sm7150 family branch exists in SimplyLuma/linux, the source is
# sm7150-mainline (what postmarketOS ships as linux-postmarketos-qcom-sm7150).
# Point KERNEL_REPO/KERNEL_REF at the fork's sm7150 branch (sm7150-mainline
# rebased onto luma-7.2) once it builds.
#
# usage: build-kernel.sh OUTPUT_DIR
# env:   KERNEL_REPO (default https://github.com/sm7150-mainline/linux)
#        KERNEL_REF  (default v7.1_rc3)
set -euo pipefail
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=$(realpath -m "${1:?usage: build-kernel.sh OUTPUT_DIR}")
repo=${KERNEL_REPO:-https://github.com/sm7150-mainline/linux}
ref=${KERNEL_REF:-v7.1_rc3}
src=${KERNEL_SRC:-$PWD/kernel-src}
jobs=$(nproc)

[ "$(uname -m)" = aarch64 ] || export ARCH=arm64 CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
export ARCH=arm64

if [ ! -d "$src/.git" ]; then
  git clone --depth 1 --branch "$ref" "$repo" "$src"
fi
git -C "$src" log -1 --format='kernel source: %H %s'
# Surya changes not (yet) in sm7150-mainline, applied once on top. Other trees
# (e.g. RedLicorice/linux-surya, which already has double tap to wake and the
# cameras) are built as they are.
patches=( "$here"/kernel-patches/*.patch )
case "$repo" in
  */sm7150-mainline/linux|*/sm7150-mainline/linux.git) ;;
  *) echo "kernel patches skipped for $repo"; patches=() ;;
esac
for patch in "${patches[@]}"; do
  [ -e "$patch" ] || continue
  if git -C "$src" apply --check -R "$patch" 2>/dev/null; then
    echo "kernel patch already applied: $(basename "$patch")"
  else
    git -C "$src" apply "$patch"
    echo "kernel patch applied: $(basename "$patch")"
  fi
done

make -C "$src" -j"$jobs" defconfig sm7150.config
"$src/scripts/kconfig/merge_config.sh" -m -O "$src" "$src/.config" "$here/sm7150-luma.fragment"
make -C "$src" -j"$jobs" olddefconfig
# Report fragment options the tree dropped (unknown symbol or unmet dependency).
grep -E '^CONFIG_[A-Z0-9_]+=' "$here/sm7150-luma.fragment" | while IFS= read -r line; do
  grep -qxF "$line" "$src/.config" || echo "note: not set as requested: $line"
done

make -C "$src" -j"$jobs" Image.gz modules \
  qcom/sm7150-xiaomi-surya-huaxing.dtb qcom/sm7150-xiaomi-surya-tianma.dtb

release=$(make -C "$src" -s kernelrelease)
rm -rf "$out" && mkdir -p "$out/dtbs/qcom"
cp "$src/arch/arm64/boot/Image.gz" "$out/"
cp "$src"/arch/arm64/boot/dts/qcom/sm7150-xiaomi-surya-{huaxing,tianma}.dtb "$out/dtbs/qcom/"
cp "$src/.config" "$out/config-$release"
make -C "$src" -j"$jobs" INSTALL_MOD_PATH="$out/modules" INSTALL_MOD_STRIP=1 modules_install
rm -f "$out/modules/lib/modules/$release/build" "$out/modules/lib/modules/$release/source"
echo "$release" > "$out/kernelrelease"
git -C "$src" rev-parse HEAD > "$out/source-commit"
(cd "$out" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
echo "Image (uncompressed): $(stat -c %s "$src/arch/arm64/boot/Image") bytes; Image.gz: $(stat -c %s "$out/Image.gz") bytes"
echo "kernel $release -> $out"
