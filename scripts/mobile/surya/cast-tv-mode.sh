#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
#
# POCO X3 NFC (surya): while the phone is casting to a screen (Miracast,
# e.g. with GNOME Network Displays), use Luma's TV posture in landscape;
# when the cast ends, go back to automatic posture in portrait.
#
# A cast is a Wi-Fi Direct (wifi-p2p) connection in NetworkManager, so that
# is what is watched. Runs in the user session (luma-cast-tv-mode.service).
#
# install: cast-tv-mode.sh --install   (as the user, not root)
set -u

if [ "${1:-}" = "--install" ]; then
  install -D -m 0755 "$0" "$HOME/.local/bin/luma-cast-tv-mode"
  mkdir -p "$HOME/.config/systemd/user"
  cat > "$HOME/.config/systemd/user/luma-cast-tv-mode.service" <<'EOF'
[Unit]
Description=TV posture and landscape while casting to a screen
After=graphical-session.target
PartOf=graphical-session.target

[Service]
ExecStart=%h/.local/bin/luma-cast-tv-mode
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now luma-cast-tv-mode.service
  systemctl --user --no-pager status luma-cast-tv-mode.service | head -5
  exit 0
fi

panel() { gdctl show 2>/dev/null | grep -oE 'DSI-[0-9]+' | head -1; }

set_mode() {  # $1 = tv | auto
  m=$(panel)
  if [ "$1" = tv ]; then
    luma-shell-statectl set posture tv
    [ -n "$m" ] && gdctl set --logical-monitor --primary --monitor "$m" --transform 90
  else
    luma-shell-statectl set posture auto
    [ -n "$m" ] && gdctl set --logical-monitor --primary --monitor "$m" --transform normal
  fi
  echo "cast: $1"
}

casting() {
  nmcli -t -f TYPE connection show --active 2>/dev/null | grep -q '^wifi-p2p$'
}

state=auto
while :; do
  if casting; then
    [ "$state" = tv ] || { set_mode tv; state=tv; }
  else
    [ "$state" = auto ] || { set_mode auto; state=auto; }
  fi
  sleep 2
done
