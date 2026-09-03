#!/usr/bin/env bash
# Runs inside the guest right after the unattended install, before the golden
# snapshot is sealed. Idempotent: safe to re-run on a live guest.
#
# stdin carries the guest sudo password (the lab generated it), so it never
# appears in the process table. Note `sudo -S` consumes stdin, so privileged
# writes go through a temp file rather than a pipe into `tee`.
set -euo pipefail

read -rs LAB_PW
sudo_() { printf '%s\n' "$LAB_PW" | sudo -S -p '' "$@"; }

user=$(id -un)

# An unattended install leaves SDDM waiting at its greeter, so a reset guest
# would have no Wayland session and every desktop test would fail on a login
# screen. Production autologins into the session SDDM recorded in
# /var/lib/sddm/state.conf; pick the same session file here.
session=""
for candidate in omarchy.desktop hyprland-uwsm.desktop hyprland.desktop; do
  for dir in /usr/local/share/wayland-sessions /usr/share/wayland-sessions; do
    [[ -f $dir/$candidate ]] && { session=$candidate; break 2; }
  done
done
[[ -n $session ]] || { echo "no wayland session file found" >&2; exit 1; }

printf '[Autologin]\nUser=%s\nSession=%s\n' "$user" "$session" > /tmp/autologin.conf
sudo_ mkdir -p /etc/sddm.conf.d
sudo_ install -m 0644 -o root -g root /tmp/autologin.conf /etc/sddm.conf.d/autologin.conf
rm -f /tmp/autologin.conf
echo "autologin: user=$user session=$session"
sudo_ cat /etc/sddm.conf.d/autologin.conf | sed 's/^/  /'

# The test suite parses TOML and JSON inside the guest.
for tool in jq python; do
  command -v "$tool" >/dev/null || sudo_ pacman -S --noconfirm --needed "$tool"
done
echo "tools: jq=$(command -v jq) python=$(command -v python)"

# A first-boot Omarchy shows onboarding overlays; suppress them so screenshots
# show the desktop under test rather than a wizard.
mkdir -p ~/.local/state/omarchy
: > ~/.local/state/omarchy/onboarded

echo "postinstall complete"
