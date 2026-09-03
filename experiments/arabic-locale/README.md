# Arabic as the system language

Worksheet + switch script. **Nothing here has been applied to the host.** The
whole point is to run it in the lab guest first.

## Verdict

Partly possible. "System language" is four independent layers, and they do not
all move together:

| Layer | Arabic? | Where it lives |
|---|---|---|
| Locale (formats, collation, `LANG`) | **Yes** | `/etc/locale.gen`, `/etc/locale.conf` |
| App UI translations + RTL mirroring | **Per app** | each app's `ar` catalogue |
| Omarchy's own bar / menus / OSD | **No** | Quickshell, ships no i18n |
| Terminal text rendering | **No** | no bidi/shaping in any terminal here |

## Baseline measured on the host

- `/etc/locale.conf` is a single line: `LANG=en_US.UTF-8`.
- Generated locales: `C`, `C.utf8`, `en_US.utf8`, `POSIX`. **No `ar_*`.**
- All 30 `ar_*` lines in `/etc/locale.gen` are commented (lines 30-59);
  `ar_SA.UTF-8 UTF-8` is line 55.
- Fonts are already fine: 26 Arabic faces from `noto-fonts`, `fc-match :lang=ar`
  resolves to Noto Naskh Arabic. Nothing to install.
- `fcitx5`, `fcitx5-gtk`, `fcitx5-qt` are installed but **irrelevant here** —
  the `ara` XKB layout is a plain keymap, Arabic needs no input method.
- `LC_ALL=en_US.UTF-8` appears in the agent's shell environment only. It is not
  set by any system file (`/etc/environment`, `/etc/profile.d`, `environment.d`,
  omarchy defaults were all checked). Worth knowing because `LC_ALL` overrides
  every `LC_*` and would silently defeat the hybrid layout below.

### Pre-existing defect, unrelated to the locale

`~/.config/hypr/input.lua:90` sets `kb_layout = "us,ara"`, but the override
block does not name `kb_options`, and Omarchy's default only appends
`grp:alts_toggle` when the *first* layout is non-Latin. `hyprctl devices`
confirms every keyboard is:

```
l "us,ara"   o "compose:caps,shift:both_capslock_cancel"
```

No `grp:` toggle, and no `switchxkblayout` bind anywhere in `~/.config/hypr/`.
The Arabic layout is loaded and unreachable. `tests/50-locale.sh` fails on this
today. Fix: `omarchy-lang keyboard [--write]`.

## What switching actually buys, and what it costs

**Gains**

- GTK and Qt apps that ship `ar` catalogues translate, and mirror their layout
  RTL automatically from the locale.
- Dates, currency, paper size (A4 vs Letter), and week start follow Arabic
  conventions.
- Chromium follows the system locale directly. Firefox needs its own catalogue:
  `omarchy pkg add firefox-i18n-ar`.

**Costs**

- `ar_*` locales emit **Arabic-Indic digits** (`٠١٢٣٤٥٦٧٨٩`) from `date`,
  `printf "%'d"`, and anything else that formats numbers through the locale.
  Any script parsing that output with `[0-9]` breaks. This is what `--mode
  hybrid` exists to avoid.
- Collation changes, so `sort` order changes.
- **Omarchy's shell stays English.** `/usr/share/omarchy/shell` contains no
  i18n, locale, or `.mo` files — the bar, menus, OSD, and notifications are not
  translatable at all.
- **Terminals cannot render Arabic.** Alacritty, foot, kitty, and ghostty have
  no bidi reordering and no Arabic glyph shaping. Arabic text appears as
  isolated letterforms in left-to-right order. No config fixes this; it needs
  upstream work in the terminal.
- Most CLI tools are English regardless.
- Half-broken RTL in apps that mirror their layout but have no `ar` strings.

## The script

`./omarchy-lang` — reversible, backs up everything it touches, never sets
`LC_ALL`.

```
omarchy-lang status                                # read-only report
omarchy-lang set ar_SA.UTF-8 [--mode MODE] [-n]    # switch
omarchy-lang reset                                 # back to en_US.UTF-8
omarchy-lang keyboard [--write]                    # fix the us/ara toggle
```

`--dry-run` / `-n` prints every privileged command instead of running it, and
needs no root at all.

### Modes

| Mode | `/etc/locale.conf` | Effect |
|---|---|---|
| `hybrid` *(default)* | `LANG=ar_SA.UTF-8` + `LC_NUMERIC`/`LC_TIME`/`LC_COLLATE` = `en_US.UTF-8` | Arabic UI and RTL, ASCII digits and stable sort order. Scripts keep working. |
| `full` | `LANG=ar_SA.UTF-8` only | Everything Arabic, Arabic-Indic digits included. |
| `formats` | `LANG=en_US.UTF-8` + Arabic `LC_TIME`/`NUMERIC`/`MONETARY`/`PAPER`/`MEASUREMENT`/`ADDRESS`/`TELEPHONE`/`NAME` | Arabic dates and numbers, English UI, no RTL. |

`hybrid` deliberately leaves `LC_PAPER` and `LC_MEASUREMENT` on the Arabic
locale — pinning those to `en_US` would hand back Letter paper and imperial
units.

### What it changes

1. Uncomments the locale in `/etc/locale.gen` and runs `locale-gen`
   (backup: `/etc/locale.gen.bak.<timestamp>`).
2. `localectl set-locale <assignments>` → `/etc/locale.conf`
   (backup: `/etc/locale.conf.bak.<timestamp>`). Note `localectl` **replaces**
   the whole file, so unlisted categories are cleared, not preserved.
3. Writes `~/.config/environment.d/95-lang.conf` with the same assignments, so
   the `systemd --user` session and the uwsm-launched Hyprland inherit it.
   Skip with `--no-user-env`.
4. Nudges the live session (`systemctl --user set-environment`,
   `dbus-update-activation-environment`, `hyprctl keyword env`) and prints
   sample `date`/number/currency output. Already-running apps keep the locale
   they started with — only a re-login is a real switch.

Order matters and the script enforces it: `systemd-localed` refuses a locale
that has not been generated yet.

## Lab test plan

`tests/50-locale.sh` (added to the suite, so plain `./lab test` picks it up)
derives its expectations from `/etc/locale.conf`, so it is meaningful before and
after the switch. It asserts: every configured locale is generated, no `LC_ALL`
is pinned, the set resolves without glibc warnings, digits stay ASCII wherever
`LC_*` is not Arabic, a font covers the configured language, the extra keyboard
layout is reachable, the first layout is Latin (Hyprland resolves keybindings
against the first layout only, so a non-Latin one in front kills every
`SUPER+<letter>` bind), and the shell plus `omarchy` CLI survive.

Baseline run on the host's synced config: 11 PASS, 1 FAIL — the unreachable
`ara` layout above.

### Run

```bash
cd ~/Work/omarchy-lab
./lab reset                       # pristine guest
./lab sync                        # push real hypr/shell/terminal configs
./lab test                        # baseline; expect the same layout FAIL

# push the script (it is not in sync/manifest on purpose)
./lab ssh 'cat > ~/omarchy-lang && chmod +x ~/omarchy-lang' \
  < experiments/arabic-locale/omarchy-lang

./lab ssh '~/omarchy-lang status'
./lab ssh '~/omarchy-lang set ar_SA.UTF-8 --mode hybrid --dry-run'
```

`sudo` in the guest wants a password (it is in `state/vm_password`), and
`./lab ssh <cmd>` has no tty — the script refuses rather than hang. So do the
real switch from an interactive shell:

```bash
./lab ssh                         # interactive, has a tty
  ./omarchy-lang set ar_SA.UTF-8 --mode hybrid
  ./omarchy-lang keyboard --write
  exit
```

Then re-login the guest session and look at it:

```bash
./lab down && ./lab up            # cleanest re-login; guest state survives
./lab test                        # 50-locale.sh should now be all PASS
./lab shot arabic-hybrid          # RTL mirroring is only verifiable visually
```

VNC on `127.0.0.1:5910` for clicking around. Check by eye:

- Does the bar still lay out sanely (it stays English — expected)?
- Do GTK apps mirror RTL and translate?
- Open a terminal and type Arabic (Left Alt + Right Alt to switch layout).
  Expect broken shaping. Confirm how bad it is before deciding.
- Does the lock screen / launcher still work?

Try `--mode full` too, on a fresh `./lab reset`, to see the Arabic-Indic digit
fallout for yourself.

### Rollback

In the guest: `./lab reset`. On the host (if it ever gets applied):
`omarchy-lang reset`, then re-login. The `.bak.<timestamp>` copies of
`locale.conf` and `locale.gen` are the belt-and-braces path.

## Promotion, when the guest proves it out

```bash
./lab promote .config/hypr/input.lua     # keyboard toggle only
```

The locale itself lives in `/etc`, which `./lab promote` does not cover (it is
`$HOME`-relative by design). Apply it on the host by hand, from a terminal:

```bash
~/Work/omarchy-lab/experiments/arabic-locale/omarchy-lang set ar_SA.UTF-8 --mode hybrid
```

## Open question the lab should settle

Whether Arabic is worth it at all given the two hard walls: no Omarchy shell
translations, and no terminal bidi. If most of your day is bar + terminal, a
`hybrid` or `formats` switch changes very little that you actually look at.
Decide after `./lab shot`.
