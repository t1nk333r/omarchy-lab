#!/usr/bin/env bash
# Validate the synced dotfiles that have real validators. `herdr config check`
# is deliberately not trusted here: it accepts unknown keys and bogus chords,
# so herdr's canonical key reference is used instead when it is reachable.
source "$(dirname "$0")/lib.sh"

# --- ghostty ---------------------------------------------------------------
if command -v ghostty >/dev/null && [[ -f $HOME/.config/ghostty/config ]]; then
  if out=$(ghostty +validate-config 2>&1); then
    pass "ghostty config valid"
  else
    fail "ghostty config invalid"; printf '%s\n' "$out" | sed 's/^/      /'
  fi
else
  skip "ghostty or its config absent"
fi

# --- tmux ------------------------------------------------------------------
if command -v tmux >/dev/null && [[ -f $HOME/.config/tmux/tmux.conf ]]; then
  if out=$(tmux -f "$HOME/.config/tmux/tmux.conf" new-session -d -s labcheck 2>&1); then
    pass "tmux.conf loads"
    tmux kill-session -t labcheck 2>/dev/null || true
  else
    fail "tmux.conf failed to load"; printf '%s\n' "$out" | sed 's/^/      /'
  fi
else
  skip "tmux or its config absent"
fi

# --- herdr -----------------------------------------------------------------
cfg=$HOME/.config/herdr/config.toml
if [[ -f $cfg ]] && command -v herdr >/dev/null; then
  ref=/tmp/herdr-config-reference.json
  ver=$(herdr --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  url="https://raw.githubusercontent.com/herdrdev/herdr/v$ver/docs/next/website/src/data/config-reference.json"
  if [[ -s $ref ]] || curl -fsSL "$url" -o "$ref" 2>/dev/null; then
    python - "$cfg" "$ref" <<'PY'
import json, sys, tomllib, pathlib
cfg = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
ref = json.loads(pathlib.Path(sys.argv[2]).read_text())
known = {k["key"]: k for s in ref["sections"] for k in s["keys"]}

def flat(d, pre=""):
    for k, v in d.items():
        p = pre + k
        if isinstance(v, dict):
            yield from flat(v, p + ".")
        else:
            yield p, v

used = dict(flat(cfg))
unknown = [k for k in used if k not in known]
chords = {}
for k, v in used.items():
    if known.get(k, {}).get("type") == "keybinding":
        for c in (v if isinstance(v, list) else [v]):
            chords.setdefault(c, []).append(k)
dupes = {c: a for c, a in chords.items() if len(a) > 1}
live = {k: (d or "").strip('"') for k, d in
        ((k, v.get("default")) for k, v in known.items() if v.get("type") == "keybinding")
        if k not in used and d and d != "unset"}
clash = {k: d for k, d in live.items() if d in chords}
bad = {k: v for k, v in used.items()
       if (a := known[k].get("allowed")) and isinstance(v, str) and v not in a}

problems = []
if unknown: problems.append(f"unknown keys: {unknown}")
if dupes:   problems.append(f"chord conflicts: {dupes}")
if clash:   problems.append(f"clashes with live defaults: {clash}")
if bad:     problems.append(f"illegal values: {bad}")
if problems:
    for p in problems: print("      " + p)
    sys.exit(1)
print(f"      {len(used)} keys, all canonical, no conflicts")
PY
    [[ $? -eq 0 ]] && pass "herdr config validated against reference" \
      || fail "herdr config has problems"
  else
    skip "herdr reference unreachable (offline)"
  fi
else
  skip "herdr or its config absent"
fi

finish
