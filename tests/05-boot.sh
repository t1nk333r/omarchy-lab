#!/usr/bin/env bash
# Runs on every distro: did this guest come up as a usable machine? These are
# the things a `reset` or `sandbox` guest must have before any experiment on it
# means anything.
source "$(dirname "$0")/lib.sh"

state=$(systemctl is-system-running 2>/dev/null || true)
# "degraded" names its own failures below, so report rather than fail on it.
[[ $state == running || $state == degraded ]] && pass "systemd: $state" \
  || fail "systemd is $state"

failed=$(systemctl list-units --state=failed --no-legend --plain 2>/dev/null | awk '{print $1}')
[[ -z $failed ]] && pass "no failed units" || {
  fail "failed units:"
  printf '      %s\n' $failed
}

[[ $(systemctl is-active sshd sshd.service ssh 2>/dev/null | grep -c '^active') -gt 0 ]] \
  && pass "sshd active" || fail "sshd not active"

# The lab's guest→host story assumes this account can escalate. `sudo -n`
# cannot prove that when a password is required (and requiring one is normal),
# so assert the membership that grants it instead.
admin=$(id -nG | tr ' ' '\n' | grep -cE '^(sudo|wheel)$')
(( admin > 0 )) && pass "$(id -un) is in an admin group" \
  || fail "$(id -un) is in neither sudo nor wheel"

# The overlay is created larger than the image it backs; without a grown
# filesystem the guest runs out of space mid-experiment.
avail=$(df -BM --output=avail / | tail -1 | tr -dc 0-9)
(( avail > 2048 )) && pass "root filesystem has ${avail}M free" \
  || fail "only ${avail}M free on / (did the filesystem grow?)"

# cloud-init only exists on the cloud images; on Omarchy this is not a failure.
if command -v cloud-init >/dev/null; then
  status=$(cloud-init status 2>/dev/null | sed 's/^status: //')
  [[ $status == "done" ]] && pass "cloud-init: done" || fail "cloud-init: $status"
else
  skip "no cloud-init (installer-provisioned guest)"
fi

finish
