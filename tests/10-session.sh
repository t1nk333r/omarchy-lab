#!/usr/bin/env bash
# The guest is a real Omarchy desktop, not just an Arch box: assert the pieces
# every later test depends on are actually running.
source "$(dirname "$0")/lib.sh"

command -v omarchy >/dev/null && pass "omarchy cli present ($(omarchy version 2>/dev/null))" \
  || fail "omarchy cli missing"

pgrep -x Hyprland >/dev/null && pass "Hyprland running" || fail "Hyprland not running"

if hypr_env; then
  pass "hyprland instance $HYPRLAND_INSTANCE_SIGNATURE"
  hyprctl -j monitors >/dev/null 2>&1 && pass "hyprctl responds" || fail "hyprctl unreachable"
else
  fail "no hyprland instance socket in $XDG_RUNTIME_DIR/hypr"
fi

pgrep -f 'quickshell|omarchy-shell' >/dev/null && pass "omarchy shell running" \
  || fail "omarchy shell not running"

finish
