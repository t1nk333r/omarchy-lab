# AGENTS.md

Instructions for AI coding agents working in this repository. Humans should
read [`README.md`](README.md) first; this file assumes it.

## What this repository is

`omarchy-lab` provisions a disposable [Omarchy](https://omarchy.org/) VM so
desktop and system changes can be tested before they are applied to a real
machine. QEMU runs inside a container with `/dev/kvm` passed through, the
Omarchy ISO installs itself unattended from a `cidata` answer drive, and the
installed disk is sealed as a golden snapshot that the guest overlays. Reverting
the guest costs seconds.

Everything is POSIX-ish bash plus Docker. There is no build step, no package
manager, and no compiled artifact.

## Ground rules

1. **Nothing may be installed on the host.** The whole point is that the host
   grows no hypervisor stack. New tooling belongs in `runner/Dockerfile`, which
   is where `qemu`, OVMF and `genisoimage` live. If a command must run on the
   host, it has to be something a stock Arch/Omarchy system already ships
   (`ssh`, `jq`, `openssl`, `tar`, `docker`).
2. **No hardcoded identity.** Username, hostname, keyboard, timezone, Omarchy
   version, ports, CPU/memory/disk and image names all come from `lab.conf`,
   which derives host-specific values at runtime (`id -un`,
   `timedatectl show -p Timezone`, `omarchy version`). Never write a personal
   username, machine name, IP or absolute `/home/<name>` path into tracked
   files.
3. **Never commit guest or host state.** `images/`, `state/`, `run/` and
   `promote-backups/` are gitignored. `state/` holds the generated guest
   password and the lab SSH private key; the repository must stay clonable
   without secrets.
4. **`./lab promote` is the only path from guest to host,** and it always writes
   a timestamped backup first. Do not add code that writes outside the
   repository or the guest without that guarantee.
5. **Keep the CLI single-file and dependency-free.** `lab` is meant to be
   readable end to end. Prefer a new subcommand there over a new script or a
   framework.

## Layout

| Path | Role |
| --- | --- |
| `lab` | the entire CLI; subcommands dispatch at the bottom of the file |
| `lab.conf` | every tunable, sourced by `lab`; each value overridable by env |
| `runner/Dockerfile` | container carrying qemu + OVMF + cdrtools |
| `runner/qmp.py` | QMP control plane (`shot`, `keys`, `mouse`); bind-mounted into the VM container, so edits need no rebuild |
| `provision/postinstall.sh` | runs in the guest after install, before sealing |
| `sync/manifest` | host paths (relative to `$HOME`) mirrored into the guest |
| `tests/` | checks that execute inside the guest; `lib.sh` is shared, not a test |
| `experiments/` | scratch space for specific investigations |

## Conventions

- **Subcommands** are `cmd_<name>()` in `lab`, registered in the `case` block at
  the end. Keep the usage header comment at the top of the file in sync.
- **Config** is read with `: "${LAB_FOO:=default}"` so environment variables
  win. Deriving a default from the host is fine; baking in a literal is not.
- **Tests** live in `tests/[0-9]*-name.sh`, source `tests/lib.sh`, and use
  `pass`/`fail`/`skip` plus a final `finish`. The runner deliberately globs
  `[0-9]*.sh` so `lib.sh` is not executed. Tests run over SSH with no graphical
  environment inherited, so use `hypr_env` and the exported `XDG_RUNTIME_DIR` /
  `OMARCHY_PATH` from `lib.sh` rather than assuming a session.
- **A failing test on a pristine guest is allowed** when it reflects a genuine
  upstream defect. Document it under "Known-red baseline" in `README.md` instead
  of weakening the assertion.
- **`sudo` in the guest** takes its password on stdin (`sudo -S -p ''`). Note
  that `sudo -S` consumes stdin, so privileged file writes go through a temp
  file and `install`, never a pipe into `tee`.
- **SSH to the guest must pass `-o IdentityAgent=none`.** A desktop `ssh-agent`
  can stall about 60 seconds per connection before refusing to list identities.
  `ssh_opts()` already does this; reuse it.
- **`runner/qmp.py` ports Oligarchy's key encoding, and that port is the spec.**
  `parseKeys` in ThePrimeagen/Oligarchy `src/qemu/keys.ts` defines the wire
  behaviour; the 41 vectors in its `keys.test.ts` must keep passing against
  `parse_keys`. The user-facing surface may diverge, the encoding may not.
- **Chords are one `input-send-event` list, never `send-key`.** `send-key`
  separates press and release by a timer, and a guest stalled under load
  autorepeats between them (`@` measured as `@@@@@`). Keep press+release
  adjacent.
- **Pointer moves are sweeps.** A single absolute warp moves the cursor but
  Hyprland's `follow_mouse` does not refocus on it; a stepped sweep from the
  last position does. `sweep()` owns the last-position file in `/labrun`.
- **The flight recorder is verbatim.** `record()` appends every `keys`, `mouse`
  and `shot` to `run/actions.log`. Anything secret goes through
  `keys --secret`, which records only the length.

## Driving the guest

When a task means operating the desktop rather than running a command over
ssh, use the control plane and follow these rules (learned driving real
Omarchy sessions, largely per Oligarchy's field guide):

1. **Look before you type.** The first action on an uncertain screen is
   `./lab shot`, never a key. A stray Enter on the wrong screen is a reinstall
   or a destroyed workspace.
2. **Act, wait ~3 s, shot, read, decide.** Never sleep more than ~10 s blind;
   for slow things (installer, reboot) keep shooting instead of trusting a long
   sleep.
3. **Rendering lags keys.** An empty prompt does not mean keys were lost, and
   keys sent to a terminal that is still launching never reach its shell. Shot
   until the prompt exists, then type. If text has not appeared, shot again
   before re-sending — double-typed input is worse than late input.
4. **Focus is mouse-shaped.** Omarchy focuses the window under the pointer;
   `./lab mouse x y` (a sweep) before typing plain text. Window-manager chords
   (`<M-ENTER>`, `<M-2>`) land regardless of focus.
5. **Menus want arrows.** TUI pickers may reset on letters; batch `<Down>` and
   shot before `<ENTER>`.
6. **A TTY is focus-proof.** `<C-A-F3>` when the desktop plays focus games or
   the shell has died; a username/password login there is the cleanest proof
   of a working system.
7. **Verify text by reading it back**, not by eye: write to a file in the guest
   and `./lab ssh cat` it when exactness matters.

## Verifying a change

There is no unit-test suite for the CLI itself. Prove changes against a real
guest:

```bash
bash -n lab && python runner/qmp.py selftest   # syntax + key-encoding vectors
./lab doctor                    # prerequisites
./lab reset                     # pristine guest (or ./lab bootstrap the first time)
./lab sync && ./lab test        # host configs in, in-guest checks
./lab shot verify               # PNG in run/shots/ — read it, do not assume
```

Rules of evidence:

- **Anything visual needs a screenshot.** `./lab shot` writes a PNG that can be
  read back. A green test says nothing about whether a desktop change looks
  right.
- **Anything touching install or snapshot flow needs a real run.** `bootstrap`,
  `golden` and `reset` manipulate qcow2 backing chains, where a mistake is
  silent data loss. In particular: a guest disk with a backing file must be
  `qemu-img commit`ted, never moved over its own backing file.
- **`lab.conf` changes need one `bootstrap` from scratch,** because most of them
  only take effect through `cidata` generation at install time.

## Upstream contracts this depends on

Changes here must stay compatible with:

- The `cidata` unattended-install contract —
  [`manual/51-unattended-installs.md`](https://github.com/omacom/omarchy/blob/quattro/manual/51-unattended-installs.md)
  and `omarchy-cidata-load` in
  [`omacom/omarchy-iso`](https://github.com/omacom/omarchy-iso).
- The archinstall JSON the ISO's own configurator writes
  (`configs/airootfs/root/configurator`). `lab cidata` mirrors its `full_disk`
  template, including partition arithmetic. When Omarchy changes it, re-derive
  from that file rather than guessing.
- Session naming: autologin resolves the session file the way the installed
  system records it in `/var/lib/sddm/state.conf`
  (`/usr/local/share/wayland-sessions/omarchy.desktop` first, then the
  `hyprland*` entries).

## Out of scope

- GPU passthrough and anything needing real hardware acceleration: graphics are
  software-rendered on purpose.
- Multi-guest orchestration. One named guest per checkout, from `lab.conf`.
- Managing the host's Omarchy configuration. This repository tests changes and
  promotes files; it is not a dotfiles manager.
