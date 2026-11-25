#!/bin/sh
# surya: the speaker setup tested on the phone (POCO X3 NFC, 7.2 kernel).
#
#  - Volume keys control a "Speaker" output (surya_media) that plays into the
#    hardware speaker, which stays at 100%. Every player (Chrome, music,
#    videos, notifications, ringtones) goes there.
#  - Short system sounds (any sound with an event id and the Notification
#    role: keypad and keyboard clicks, the volume-key sound) skip that output
#    and play on the hardware speaker at a fixed level. Luma's volume keys
#    follow the sound role that is playing, so these must stay out of the
#    role loopbacks, or the keys change them instead of the music. They are matched by sound, not by
#    program: an earlier PULSE_SINK on the shell was inherited by every app it
#    opened, and Chrome then bypassed the volume keys.
#  - Players always follow the volume-key output (no remembered old outputs).
#  - Clicks are quieter files (CLICK_LEVEL of the theme sound), made once per
#    user; an existing level is never overwritten.
#
# usage: sudo surya-audio-setup.sh           on the phone (system + users), then reboot
#        surya-audio-setup.sh --root DIR     into an offline deployment (system part)
#        sudo surya-audio-setup.sh --check   on the phone: show where sound goes
set -eu
HW=alsa_output.platform-sound.HiFi__Speaker__sink
CLICK_LEVEL=0.52
root=
case "${1:-}" in
  --root) root=${2:?usage: surya-audio-setup.sh --root DIR} ;;
  --check) check=1 ;;
  "") ;;
  *) echo "usage: surya-audio-setup.sh [--root DIR | --check]" >&2; exit 2 ;;
esac

if [ -n "${check:-}" ]; then
  u=$(loginctl list-users --no-legend | awk '$1 >= 1000 {print $2; exit}')
  uid=$(id -u "$u")
  runuser -u "$u" -- env XDG_RUNTIME_DIR=/run/user/$uid python3 - <<'EOF'
import json, subprocess, time
print("for 20 s: type, tap the keypad and play something", flush=True)
seen = set(); end = time.time() + 20
while time.time() < end:
    d = json.loads(subprocess.run(["pw-dump"], capture_output=True, text=True).stdout or "[]")
    n = {o["id"]: o["info"]["props"] for o in d if o.get("type") == "PipeWire:Interface:Node" and o.get("info")}
    for o in d:
        if o.get("type") == "PipeWire:Interface:Link" and o.get("info"):
            s = n.get(o["info"]["output-node-id"], {}); t = n.get(o["info"]["input-node-id"], {})
            if s.get("media.class") == "Stream/Output/Audio" and not s.get("node.name", "").startswith(("output.loopback", "surya_media")):
                who = s.get("application.process.binary") or s.get("node.name")
                lane = "fixed (clicks)" if t.get("node.name", "").startswith("alsa_output") else "volume keys"
                k = (who, s.get("event.id", s.get("media.name", "")), lane)
                if k not in seen:
                    seen.add(k); print(f"{k[0]:16} {k[1]:16} -> {lane}", flush=True)
    time.sleep(0.15)
EOF
  exit 0
fi

# --- system part -----------------------------------------------------------
if [ -n "$root" ]; then scripts=$root/usr/share/wireplumber/scripts
elif mkdir -p /usr/local/share/wireplumber/scripts 2>/dev/null; then scripts=/usr/local/share/wireplumber/scripts
else scripts=; fi

install -d -m 0755 "$root/etc/pipewire/pipewire.conf.d" "$root/etc/wireplumber/wireplumber.conf.d"
cat > "$root/etc/pipewire/pipewire.conf.d/60-surya-media.conf" <<EOF
# surya: the output the volume keys control. It plays into the hardware
# speaker, which stays at 100% (clicks play there directly).
context.modules = [
  { name = libpipewire-module-loopback
    args = {
      node.description = "Speaker"
      capture.props = {
        node.name = "surya_media"
        media.class = "Audio/Sink"
        audio.position = [ FL FR ]
        priority.session = 2000
      }
      playback.props = {
        node.name = "surya_media.out"
        node.description = "Speaker (media to hardware)"
        target.object = "$HW"
        node.passive = true
      }
    }
  }
]
EOF
cat > "$root/etc/wireplumber/wireplumber.conf.d/60-surya-audio.conf" <<EOF
# surya: players always follow the volume-key output; the hardware speaker
# starts at 100% and is never picked as the default output.
wireplumber.settings = {
  node.stream.restore-target = false
  device.routes.default-sink-volume = 1.0
}
monitor.alsa.rules = [
  {
    matches = [ { node.name = "$HW" } ]
    actions = { update-props = { priority.session = 1 } }
  }
]
wireplumber.components = [
  {
    name = linking/surya-fixed-clicks.lua, type = script/lua
    provides = hooks.linking.target.surya-fixed-clicks
  }
]
wireplumber.profiles = {
  main = {
    hooks.linking.target.surya-fixed-clicks = required
  }
}
EOF
write_hook() {
  install -d -m 0755 "$1/linking"
  cat > "$1/linking/surya-fixed-clicks.lua" <<EOF
-- surya: short system sounds (keypad and keyboard clicks, the volume-key
-- sound) play on the hardware speaker at a fixed level. Luma's volume keys
-- control whichever sound role is playing; these sounds have the
-- Notification role, so in the role loopback they took the volume keys over
-- (keys changed the clicks, not the music) and ducked the music.
-- Matched by sound (event.id), so nothing is passed on to other apps.
lutils = require ("linking-utils")
log = Log.open_topic ("s-linking")

local HW = "$HW"
local caught = 0
log:warning ("surya-fixed-clicks loaded")

SimpleEventHook {
  name = "linking/surya-fixed-clicks",
  after = { "linking/find-defined-target", "linking/find-filter-target" },
  before = "linking/find-media-role-target",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-target" },
    },
  },
  execute = function (event)
    local _, om, si, si_props, _, target =
        lutils:unwrap_select_target_event (event)
    if target then
      return
    end
    local id = si_props ["event.id"]
    local name = si_props ["media.name"]
    if id == nil and (name == "button-pressed" or name == "button-released" or
        name == "audio-volume-change") then
      id = name
    end
    local role = si_props ["media.role"]
    if id == nil or (role ~= nil and role ~= "Notification" and role ~= "event") then
      return
    end
    local hw = om:lookup {
      type = "SiLinkable",
      Constraint { "node.name", "=", HW },
    }
    if hw and lutils.canLink (si_props, hw) then
      if caught < 3 then
        caught = caught + 1
        log:warning (si, "surya: '" .. id .. "' to the fixed speaker")
      end
      event:set_data ("target", hw)
    end
  end
}:register ()
EOF
}
[ -n "$scripts" ] && write_hook "$scripts"
[ -n "$root" ] && { echo "surya audio setup written into $root"; exit 0; }

# The sound card can come back after a DSP restart without the session
# user's access; the boot script grants it again (older images lack this).
wu=/etc/luma-surya/wifi-up.sh
if [ -f "$wu" ] && ! grep -q 'setfacl -m "u:$u:rw" /dev/snd' "$wu"; then
  python3 - "$wu" <<'EOF'
import sys
p = sys.argv[1]; s = open(p).read()
a = '    systemctl --user -M "$u@" restart wireplumber'
if a in s:
    s = s.replace(a, '    setfacl -m "u:$u:rw" /dev/snd/* 2>/dev/null\n' + a, 1)
    open(p, "w").write(s)
EOF
fi

# --- user part (every user with a home) ------------------------------------
for home in /home/*; do
  u=$(basename "$home"); id "$u" >/dev/null 2>&1 || continue
  [ "$(id -u "$u")" -ge 1000 ] || continue
  usermod -aG audio "$u" 2>/dev/null || true
  # Earlier per-user tries (replaced by the system files above).
  rm -f "$home/.config/pipewire/pipewire.conf.d/60-surya-media.conf" \
        "$home/.config/wireplumber/wireplumber.conf.d/60-surya-follow-default.conf" \
        "$home/.config/wireplumber/wireplumber.conf.d/61-surya-speaker-priority.conf" \
        "$home/.config/systemd/user/org.gnome.Shell@user.service.d/60-surya-system-sounds.conf" \
        "$home/.local/share/dbus-1/services/org.sigxcpu.Feedback.service"
  rmdir "$home/.config/systemd/user/org.gnome.Shell@user.service.d" 2>/dev/null || true
  write_hook "$home/.local/share/wireplumber/scripts"
  chown -R "$u:" "$home/.local/share/wireplumber"
  # Quieter clicks, once (keeps a level already set by hand).
  for theme in luma freedesktop; do
    dst=$home/.local/share/sounds/$theme/stereo/button-pressed.wav
    [ -e "$dst" ] && continue
    src=
    for f in /usr/share/sounds/$theme/stereo/button-pressed.wav \
             /usr/share/sounds/$theme/stereo/button-pressed.oga \
             /usr/share/sounds/$theme/stereo/button-pressed.ogg; do
      [ -e "$f" ] && { src=$f; break; }
    done
    [ -n "$src" ] || continue
    install -d -o "$u" -g "$u" "$home/.local/share/sounds" "$home/.local/share/sounds/$theme" "$home/.local/share/sounds/$theme/stereo"
    tmp=$(mktemp --suffix=.wav)
    case "$src" in
      *.wav) cp "$src" "$tmp" ;;
      *) gst-launch-1.0 -q filesrc location="$src" ! decodebin ! audioconvert ! \
           audio/x-raw,format=S16LE ! wavenc ! filesink location="$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; continue; } ;;
    esac
    python3 - "$tmp" "$dst" "$CLICK_LEVEL" <<'EOF'
import array, sys, wave
src, dst, level = sys.argv[1], sys.argv[2], float(sys.argv[3])
with wave.open(src, "rb") as w:
    p = w.getparams(); a = array.array("h", w.readframes(p.nframes))
for i in range(len(a)):
    a[i] = int(a[i] * level)
with wave.open(dst, "wb") as w:
    w.setparams(p); w.writeframes(a.tobytes())
EOF
    rm -f "$tmp"; chown "$u:" "$dst"
  done
  # Players back on the volume keys now; the rest applies after a reboot.
  uid=$(id -u "$u")
  [ -d /run/user/$uid ] && runuser -u "$u" -- env XDG_RUNTIME_DIR=/run/user/$uid \
    pw-metadata 0 default.configured.audio.sink '{"name":"surya_media"}' >/dev/null 2>&1 || true
done
echo "surya audio setup installed; reboot the phone to apply it"
