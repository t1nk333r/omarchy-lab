#!/usr/bin/env bash
# Reload the Hyprland config the way a real edit would, then demand a clean
# error report. This is the test that catches a bad binding or rule before it
# reaches production.
source "$(dirname "$0")/lib.sh"

hypr_env || { fail "no hyprland instance"; finish; }

if hyprctl reload >/dev/null 2>&1; then
  pass "hyprctl reload"
else
  fail "hyprctl reload failed"
fi

errors=$(hyprctl configerrors 2>&1)
if [[ -z $errors || $errors == *"no errors"* ]]; then
  pass "hyprctl configerrors clean"
else
  fail "config errors:"
  printf '%s\n' "$errors" | sed 's/^/      /'
fi

# Bindings must survive the reload: an empty list means the config never loaded.
count=$(hyprctl -j binds 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
(( count > 0 )) && pass "$count keybindings loaded" || fail "no keybindings loaded"

finish
