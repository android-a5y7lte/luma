# Xiaomi POCO X3 NFC (surya)

**Experimental bring-up.** No Luma image for this phone has been published or
qualified. These steps are for the maintainer and other porters testing builds
from the `surya` branch of a Luma fork. Nothing here is offered to people who
did not go looking for it.

This profile targets the POCO X3 NFC (`surya`, M2007J20CG) with the **Huaxing**
display panel. The POCO X3 (`karna`, India) and phones with the Tianma panel
need a different device tree; do not boot this image on them.

## What works

Stage 1 (2026-11-21): kernel 7.1.0-rc3 from sm7150-mainline with Luma's
options, started from U-Boot: eight CPUs, display, UFS storage, USB
networking.

Stage 2 (2026-11-22), the Luma ARM nightly 1.0.0-nightly.20261119.2 with its
root served from the computer over USB, booted with
`luma-surya-stage2-usb-root-safe-huaxing.img`: Luma's systemd, OSTree
deployment and services start, greenboot reports GREEN, GDM and GNOME Shell
show the lock screen on the Huaxing panel, touch works (Novatek NT36672 with
its firmware), the on-screen keyboard works once a keyboard layout is set,
login as `luma` works, SSH over USB works, Bluetooth controller (WCN399x)
detected.

Not yet: starting the modem, audio and compute DSPs, Wi-Fi, video or camera
resets the phone, so the "safe" image keeps their modules from loading; the
Adreno 618 had no GMU firmware (`qcom/a630_gmu.bin`; the A618 entry of a6xx_catalog.c names it), so drawing is done by
the CPU; Bluetooth lacks `qca/crbtfw01.tlv`; microphone/earpiece audio and
cameras are not supported by mainline yet (postmarketOS reports the same).

## Before you start

1. Unlock the bootloader with Xiaomi's official unlock tool. Unlocking wipes
   the phone.
2. Back up anything you need from Android. Installing Luma (stage 2) replaces
   userdata.
3. Check the panel: in Android, `cat /proc/cmdline` over `adb shell` names
   either `huaxing` or `tianma` in the display argument.
4. Install `fastboot` on your computer and boot the phone to fastboot
   (Volume Down + Power).

## Stage 1: RAM boot through U-Boot

Xiaomi's bootloader applies the overlays in the `dtbo` partition to the
device tree it boots. They are written for Android's device tree, and with
the mainline one the boot fails: the phone is back in fastboot after
`Booting OKAY`. As for postmarketOS, `dtbo` must be erased once. Android
needs `dtbo`, so back it up first and restore it to go back. Nothing else
is written.

Back up `dtbo` from a recovery with root adb (LineageOS recovery, TWRP or
OrangeFox), then check that both hashes match:

```sh
adb shell 'dd if=/dev/block/by-name/dtbo of=/tmp/dtbo.img && sha256sum /tmp/dtbo.img'
adb pull /tmp/dtbo.img surya-backup-dtbo.img
sha256sum surya-backup-dtbo.img
adb reboot bootloader
```

Erase `dtbo` and RAM-boot U-Boot (`u-boot-surya-huaxing.img` from the
build's U-Boot artifact):

```sh
fastboot getvar product            # must print: surya
fastboot erase dtbo
fastboot boot u-boot-surya-huaxing.img
```

U-Boot finds no Luma install and stops at "Press any key to continue".
Press a volume key, choose "Enable fastboot mode" with the volume keys and
Power, then RAM-boot Linux through U-Boot's fastboot (it may need root on
the computer, as U-Boot uses different USB IDs):

```sh
fastboot boot luma-surya-stage1-huaxing-v2.img
```

A good result is "Luma on POCO X3 NFC: stage 1" on the screen and a USB
network device on the computer. Give it 172.16.42.2/24, then
`telnet 172.16.42.1` for a shell; `dmesg` shows how far the hardware came
up. Holding Power for 10 seconds restarts the phone.

To go back to Android:

```sh
fastboot flash dtbo surya-backup-dtbo.img
```

## Stage 2: Luma with its root on the computer (USB)

Nothing is written to the phone: the root file system stays on the computer
and the phone reads and writes it over the USB network (NBD). It is slower
than a real install, but userdata, and whatever is on it, is left alone.

You need, from one build: Luma's generic phone userdata image
(`luma-phone-userdata.simg.zst`, the build's "luma-phone-userdata" artifact,
made when the run was started with "rootfs" or the commit names `[rootfs]`),
and from the stage 1 artifact `modules-*.tar.zst`,
`luma-surya-stage2-usb-root-huaxing.img` and `serve-usb-root.sh`.

On the computer (the first run unpacks and prepares the image, adding the
surya modules and the phone's firmware, which it downloads itself):

```sh
sudo apt install zstd android-sdk-libsparse-utils qemu-utils git
sudo ./serve-usb-root.sh luma-phone-userdata.simg.zst modules-*.tar.zst
```

On the phone, with `dtbo` erased as in stage 1: RAM-boot U-Boot, choose
"Enable fastboot mode", then

```sh
fastboot boot luma-surya-stage2-usb-root-huaxing.img
```

The script sees the phone's USB network and starts serving; the phone
connects, mounts LumaRoot and starts Luma's systemd. If it cannot, it stays in
the stage 1 debug shell (`telnet 172.16.42.1`). Keep the cable in and the
script running: the phone has no root without them.

## Firmware

`firmware.manifest` lists the firmware this phone needs, by name and SHA-256.
The files come from the phone's own firmware, as collected by the
sm7150-mainline project
(<https://github.com/sm7150-mainline/firmware-xiaomi-surya>). They are not in
this repository and are not redistributed by Luma.

## Going back to Android

Flash the official MIUI fastboot ROM for your region with Xiaomi's flash tool,
choosing "clean all" and never "clean all and lock".
