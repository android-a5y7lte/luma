#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Assembles a surya boot image (Android boot header v2) from a kernel build,
# a DTB and a ramdisk, with the format and offsets of socs/qcom/sm7150/soc.toml
# and the command line of devices/xiaomi/surya/boot.toml.
#
# usage: build-boot-image.sh KERNEL_OUT_DIR RAMDISK OUTPUT [huaxing|tianma] [debug]
#   debug: stage 1 command line (console on the panel, no Luma root arguments)
# Needs mkbootimg (AOSP; Ubuntu package "mkbootimg") and python3 >= 3.11.
set -euo pipefail
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
kout=$(realpath -e "${1:?}"); ramdisk=$(realpath -e "${2:?}"); output=$(realpath -m "${3:?}")
panel=${4:-huaxing}; mode=${5:-luma}
case "$panel" in huaxing|tianma) ;; *) echo "panel must be huaxing or tianma" >&2; exit 2 ;; esac
dtb="$kout/dtbs/qcom/sm7150-xiaomi-surya-$panel.dtb"
[ -f "$dtb" ] || { echo "missing $dtb" >&2; exit 1; }

eval "$(python3 - "$repo_root" "$mode" <<'PY'
import sys, tomllib, shlex
root, mode = sys.argv[1], sys.argv[2]
soc = tomllib.load(open(f"{root}/socs/qcom/sm7150/soc.toml", "rb"))
boot = tomllib.load(open(f"{root}/devices/xiaomi/surya/boot.toml", "rb"))
o = soc["boot"]["offsets"]
assert soc["boot"]["format"] == "android-boot-v2"
if mode == "debug":
    args = ["console=tty0", "loglevel=7", "fbcon=rotate:0", "rdinit=/init", "enforcing=0"]
else:
    args = list(boot["cmdline"]["args"])
for k, v in {"PAGE": soc["boot"]["page_size"], "BASE": o["base"], "KOFF": o["kernel"],
             "ROFF": o["ramdisk"], "SOFF": o["second"], "TOFF": o["tags"], "DOFF": o["dtb"],
             "CMDLINE": " ".join(args)}.items():
    print(f"{k}={shlex.quote(str(v))}")
PY
)"

mkbootimg --header_version 2 \
  --kernel "$kout/Image.gz" --ramdisk "$ramdisk" --dtb "$dtb" \
  --pagesize "$PAGE" --base "$(printf '0x%08x' "$BASE")" \
  --kernel_offset "$(printf '0x%08x' "$KOFF")" --ramdisk_offset "$(printf '0x%08x' "$ROFF")" \
  --second_offset "$(printf '0x%08x' "$SOFF")" --tags_offset "$(printf '0x%08x' "$TOFF")" \
  --dtb_offset "$(printf '0x%08x' "$DOFF")" \
  --cmdline "$CMDLINE" -o "$output"
size=$(stat -c %s "$output")
max=$(python3 -c "import tomllib;print(tomllib.load(open('$repo_root/devices/xiaomi/surya/boot.toml','rb'))['partition_size'])")
[ "$size" -le "$max" ] || { echo "boot image $size bytes exceeds the boot partition ($max)" >&2; exit 1; }
sha256sum "$output"
