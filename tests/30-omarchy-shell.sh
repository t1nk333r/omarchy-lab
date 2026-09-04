#!/usr/bin/env bash
# shell.json drives the bar, notifications and idle/lock timings. It hot-reloads,
# so a malformed file degrades the desktop silently — validate it and prove the
# running shell still answers IPC.
source "$(dirname "$0")/lib.sh"

cfg=$HOME/.config/omarchy/shell.json
if [[ -f $cfg ]]; then
  jq -e . "$cfg" >/dev/null 2>&1 && pass "shell.json parses" || fail "shell.json is not valid JSON"
  for k in idle.lock idle.screensaver; do
    v=$(jq -r ".$k // empty" "$cfg" 2>/dev/null)
    [[ -n $v ]] && pass "$k = $v" || skip "$k not set (using default)"
  done
else
  skip "no user shell.json (stock defaults)"
fi

if command -v omarchy-shell >/dev/null; then
  reply=$(omarchy-shell shell ping 2>&1 || true)
  [[ -n $reply ]] && pass "shell ipc: $reply" || fail "shell ipc gave no reply"
  # The lock plugin is the one surface that can strand a session; assert its
  # IPC target exists and reports a sane state.
  locked=$(omarchy-shell lock isLocked 2>&1 || true)
  [[ $locked == true || $locked == false ]] && pass "lock isLocked = $locked" \
    || fail "lock ipc unavailable ($locked)"
else
  fail "omarchy-shell missing"
fi

finish
