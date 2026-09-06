# shellcheck shell=bash
# Shared helpers for lab tests. Sourced by every tests/*.sh, which run inside
# the guest over ssh — i.e. with no graphical session environment inherited.
set -uo pipefail

pass() { printf '  PASS %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; FAILED=1; }
skip() { printf '  SKIP %s\n' "$*"; }
FAILED=0

export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}

# Distro gate. The lab can boot Omarchy (a full desktop) or a headless cloud
# image; a test that needs Hyprland says so and skips itself elsewhere.
LAB_DISTRO=${LAB_DISTRO:-omarchy}
needs_distro() { # needs_distro omarchy
  for d in "$@"; do [[ $LAB_DISTRO == "$d" ]] && return 0; done
  printf '  SKIP needs %s, this guest is %s\n' "$*" "$LAB_DISTRO"
  exit 0
}

# omarchy-shell refuses to run without OMARCHY_PATH, which the graphical
# session exports but an ssh session does not inherit.
export OMARCHY_PATH=${OMARCHY_PATH:-/usr/share/omarchy}
# Hyprland's control socket is per-instance; an ssh session has no signature, so
# recover it the same way omarchy-shell recovers WAYLAND_DISPLAY.
hypr_env() {
  local sig
  sig=$(ls -t "$XDG_RUNTIME_DIR"/hypr 2>/dev/null | head -n1) || return 1
  [[ -n ${sig:-} ]] || return 1
  export HYPRLAND_INSTANCE_SIGNATURE=$sig
  # Any live wayland-N socket (a lab guest has exactly one), skipping the .lock
  # files that sit beside them.
  local sock
  for sock in "$XDG_RUNTIME_DIR"/wayland-[0-9]*; do
    [[ $sock == *.lock ]] && continue
    [[ -S $sock ]] && export WAYLAND_DISPLAY=${sock##*/}
  done
  return 0
}

finish() { exit "$FAILED"; }
