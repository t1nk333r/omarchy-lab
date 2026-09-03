#!/usr/bin/env bash
# Locale coherence. Expectations are derived from /etc/locale.conf itself, so
# this test is meaningful on a baseline en_US guest (nothing half-configured)
# and grows teeth once experiments/arabic-locale/omarchy-lang has switched the
# guest to Arabic.
source "$(dirname "$0")/lib.sh"

CONF=/etc/locale.conf
ENV_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/environment.d

[[ -r $CONF ]] || { fail "$CONF unreadable"; finish; }

# --- what is configured -----------------------------------------------------

declare -a ASSIGN=()
while read -r line; do
  [[ $line =~ ^(LANG|LC_[A-Z_]+)=(.+)$ ]] || continue
  ASSIGN+=("${BASH_REMATCH[1]}=${BASH_REMATCH[2]//\"/}")
done < "$CONF"

(( ${#ASSIGN[@]} )) && pass "locale.conf: ${ASSIGN[*]}" \
  || { fail "$CONF names no LANG/LC_* assignment"; finish; }

lang=""
for a in "${ASSIGN[@]}"; do [[ $a == LANG=* ]] && lang=${a#LANG=}; done
[[ -n $lang ]] && pass "LANG=$lang" || fail "no LANG in $CONF"

# --- every named locale must actually exist ---------------------------------

# An unlisted or ungenerated locale does not fail loudly at login; glibc falls
# back to C and every app quietly loses its formatting.
normalise() { printf '%s' "${1,,}" | sed 's/utf-8/utf8/'; }
generated=$(locale -a 2>/dev/null | while read -r l; do normalise "$l"; echo; done)
for a in "${ASSIGN[@]}"; do
  want=$(normalise "${a#*=}")
  if grep -qxF "$want" <<<"$generated"; then
    pass "${a#*=} generated"
  else
    fail "${a#*=} is configured but not generated (run locale-gen)"
  fi
done

# --- LC_ALL must not be pinned ----------------------------------------------

# LC_ALL overrides every other category, so it silently defeats the hybrid and
# formats layouts the switch script writes.
grep -q '^LC_ALL=' "$CONF" && fail "LC_ALL pinned in $CONF" || pass "no LC_ALL in $CONF"
if compgen -G "$ENV_DIR/*.conf" >/dev/null; then
  grep -h '^LC_ALL=' "$ENV_DIR"/*.conf >/dev/null 2>&1 \
    && fail "LC_ALL pinned in $ENV_DIR" || pass "no LC_ALL in $ENV_DIR"
fi

# --- the configured set resolves without warnings ---------------------------

# env -i also clears PATH, so the probed binaries are named absolutely.
warn=$(env -i "${ASSIGN[@]}" /usr/bin/locale 2>&1 >/dev/null)
[[ -z $warn ]] && pass "configured locale resolves cleanly" \
  || fail "locale warnings: $(tr '\n' ' ' <<<"$warn")"

# --- script-facing formats stay parseable -----------------------------------

lc_time=$lang lc_numeric=$lang
for a in "${ASSIGN[@]}"; do
  [[ $a == LC_TIME=* ]] && lc_time=${a#LC_TIME=}
  [[ $a == LC_NUMERIC=* ]] && lc_numeric=${a#LC_NUMERIC=}
done

d=$(env -i "${ASSIGN[@]}" /usr/bin/date '+%Y %m %d')
n=$(env -i "${ASSIGN[@]}" /usr/bin/printf "%'d" 1234567)
printf '  info date(LC_TIME=%s)=%s number(LC_NUMERIC=%s)=%s\n' "$lc_time" "$d" "$lc_numeric" "$n"

# ar_* locales emit Arabic-Indic digits (U+0660..U+0669), which break anything
# that parses date/number output with [0-9].
if [[ $lc_time == ar_* ]]; then
  skip "LC_TIME is Arabic; non-ASCII digits in date output are expected"
else
  [[ $d =~ ^[0-9\ ]+$ ]] && pass "date output is ASCII digits" \
    || fail "date output is not ASCII under LC_TIME=$lc_time: $d"
fi
if [[ $lc_numeric == ar_* ]]; then
  skip "LC_NUMERIC is Arabic; non-ASCII digits in numbers are expected"
else
  [[ $n =~ ^[0-9,.\']+$ ]] && pass "grouped numbers are ASCII digits" \
    || fail "number output is not ASCII under LC_NUMERIC=$lc_numeric: $n"
fi

# --- font coverage for the configured language ------------------------------

script_lang=${lang%%_*}
if [[ -n $script_lang && $script_lang != en && $script_lang != C ]]; then
  faces=$(fc-list ":lang=$script_lang" 2>/dev/null | wc -l)
  (( faces )) && pass "$faces font face(s) cover :lang=$script_lang ($(fc-match ":lang=$script_lang" family 2>/dev/null))" \
    || fail "no font covers :lang=$script_lang; UI will render tofu"
fi

# --- keyboard: a second layout needs a way to reach it ----------------------

if hypr_env && hyprctl -j devices >/dev/null 2>&1; then
  rules=$(hyprctl devices | grep -m1 'rules:')
  layouts=$(sed -n 's/.*l "\([^"]*\)".*/\1/p' <<<"$rules")
  options=$(sed -n 's/.*o "\([^"]*\)".*/\1/p' <<<"$rules")
  printf '  info kb_layout=%s kb_options=%s\n' "$layouts" "$options"

  if [[ $lang == ar_* ]]; then
    [[ $layouts == *ara* ]] && pass "'ara' layout loaded" \
      || fail "LANG is Arabic but no 'ara' layout in kb_layout=$layouts"
  fi
  if [[ $layouts == *,* ]]; then
    commas=${layouts//[^,]/}
    if [[ $options == *grp:* ]]; then
      pass "layout switch configured ($(grep -o 'grp:[a-z_]*' <<<"$options"))"
    elif hyprctl binds 2>/dev/null | grep -q 'switchxkblayout'; then
      pass "layout switch bound via switchxkblayout"
    else
      fail "kb_layout lists $(( ${#commas} + 1 )) layouts but has no grp: option and no switchxkblayout bind - every layout after the first is unreachable"
    fi
  fi

  # Hyprland resolves keybindings against the FIRST layout only, so a non-Latin
  # layout in front makes every Latin-keysym Omarchy binding dead.
  first=${layouts%%,*}
  case " af am ara bd bg by et ge gr il in iq ir kg kh kz la lk mk mm mn mv np rs ru sy th tj ua " in
    *" $first "*) fail "first kb_layout '$first' is non-Latin; SUPER+<letter> bindings will not fire" ;;
    *) pass "first kb_layout '$first' is Latin; keybindings resolve" ;;
  esac
else
  skip "hyprland unreachable; keyboard checks skipped"
fi

# --- the desktop survived the switch ----------------------------------------

# Quickshell and the omarchy CLI parse numbers and dates; a locale flip is
# exactly the kind of change that breaks them.
pgrep -f 'quickshell|omarchy-shell' >/dev/null && pass "omarchy shell still running" \
  || fail "omarchy shell not running after locale change"
v=$(omarchy version 2>&1) && pass "omarchy cli works under this locale ($v)" \
  || fail "omarchy cli failed under this locale: $v"

finish
