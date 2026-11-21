# Xiaomi POCO X3 NFC (surya)

**Experimental bring-up.** No Luma image for this phone has been published or
qualified. These steps are for the maintainer and other porters testing builds
from the `surya` branch of a Luma fork. Nothing here is offered to people who
did not go looking for it.

This profile targets the POCO X3 NFC (`surya`, M2007J20CG) with the **Huaxing**
display panel. The POCO X3 (`karna`, India) and phones with the Tianma panel
need a different device tree; do not boot this image on them.

## What works

Bring-up has not started on hardware yet. The kernel and firmware come from the
sm7150-mainline project, where postmarketOS reports display, touch, GPU,
Wi-Fi, Bluetooth, charging and modem working, with microphone/earpiece audio
and cameras not working. Expect at least the same gaps here.

## Before you start

1. Unlock the bootloader with Xiaomi's official unlock tool. Unlocking wipes
   the phone.
2. Back up anything you need from Android. Installing Luma (stage 2) replaces
   userdata.
3. Check the panel: in Android, `cat /proc/cmdline` over `adb shell` names
   either `huaxing` or `tianma` in the display argument.
4. Install `fastboot` on your computer and boot the phone to fastboot
   (Volume Down + Power).

## Stage 1: RAM boot (nothing is written)

Download `luma-surya-stage1-huaxing.img` from the latest "surya build" run
(GitHub, Actions tab, the run, Artifacts), unzip it, then:

```sh
fastboot getvar product            # must print: surya
fastboot boot luma-surya-stage1-huaxing.img
```

`fastboot boot` loads the image into memory only; the phone's partitions are
not changed, and holding Power for 10 seconds returns to Android.

Stage 1 is a bring-up image, not Luma yet: a kernel and a tiny debug
initramfs. A good result is the text "Luma on POCO X3 NFC: stage 1" on the
screen, and a USB network device on your computer. Give your computer
172.16.42.2/24 on it if DHCP does not, then `telnet 172.16.42.1` for a shell;
`dmesg` shows how far the hardware came up.

## Stage 2: root filesystem on userdata

Not ready. This stage will write the Luma ARM image to userdata, in the same
layout as the Fairphone 6. It erases userdata and nothing else: modem,
calibration and identity partitions are never written.

## Firmware

`firmware.manifest` lists the firmware this phone needs, by name and SHA-256.
The files come from the phone's own firmware, as collected by the
sm7150-mainline project
(<https://github.com/sm7150-mainline/firmware-xiaomi-surya>). They are not in
this repository and are not redistributed by Luma.

## Going back to Android

Flash the official MIUI fastboot ROM for your region with Xiaomi's flash tool,
choosing "clean all" and never "clean all and lock".
