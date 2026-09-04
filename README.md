# omarchy-lab

A disposable [Omarchy](https://omarchy.org/) VM you can break, drive, and throw
away. Test a Hyprland binding, a shell plugin, a locale switch, a lock-screen
change — anything you would rather not try on your real machine first — then
revert to a known-good snapshot in about 18 seconds.

It is built for two operators: you at a terminal, and coding agents. Every
command is non-interactive, exits with a status, and leaves evidence a machine
can read (a PNG, a log line, a test result).

```bash
./lab reset                        # pristine Omarchy, ~18 s
./lab sync                         # mirror your ~/.config into it
./lab ssh 'hyprctl configerrors'   # poke at it
./lab test                         # session, hyprctl, shell IPC, dotfiles
./lab shot after                   # look at it: run/shots/after.png
./lab promote .config/hypr/input.lua   # copy the verified file home, with a backup
```

The guest is the same Omarchy release as the host, installed unattended from
the official ISO, with the same username, so configs move between the two
without rewriting. By default it has **no network at all** — see
[Security model](#security-model).

## Setup

Requirements: `/dev/kvm` readable and writable by your user, Docker access,
~70 GB free, and stock host tools (`ssh`, `ssh-keygen`, `curl`, `openssl`,
`jq`, `tar`, `sha256sum`, `timedatectl`). Nothing gets installed on the host —
QEMU lives in a container.

```bash
./lab doctor        # checks all of the above
./lab build         # qemu runner image, ~230 MB
./lab fetch-iso     # Omarchy ISO, 5.8 GB, sha256-verified, resumable
./lab bootstrap     # unattended install → autologin → golden snapshot
```

`bootstrap` boots the ISO with a generated `cidata` answer drive, waits for the
guest to install itself and reboot, provisions autologin, waits for Omarchy's
first-run setup to finish, then seals the disk as `images/golden.qcow2`. The
ISO carries its own packages, so this is offline: ~4.5 minutes on 6 vCPUs.
Watch it with `./lab logs 60` (serial console) or `./lab shot boot`.

Credentials land in `state/` (mode 700): a generated guest password and a
dedicated ssh key the ISO installs as the guest's `authorized_keys`.

## Commands

| Command | Does |
| --- | --- |
| `up` / `down` | start the guest / graceful powerdown |
| `reset` | discard the guest, recreate from golden, boot — the undo |
| `sandbox [cmd]` | fresh guest, network forced off, **deleted on exit** |
| `status` | container, snapshot sizes, network mode, guest identity |
| `ssh [cmd]` | shell or one command in the guest |
| `sync` | push the paths in `sync/manifest` from `$HOME` into the guest |
| `test` | run `tests/` inside the guest; exit 1 on any failure |
| `shot [name]` | PNG of the guest display → `run/shots/<name>.png` |
| `keys "<s>"` | type into the guest over QMP; `--secret` hides it from the log |
| `mouse x y [btn] [n]` | move the pointer (fractions of the screen), optionally click |
| `promote <rel>…` | copy guest files to `$HOME`, backup first, hostile-input checks |
| `logs [n]` | guest serial console |
| `provision` | re-apply autologin and test tooling (idempotent) |
| `golden` | seal the current guest state as the new revert point |
| `cidata` / `fetch-iso` / `build` | regenerate the answer drive / ISO / runner |
| `destroy` | delete disks; keeps ISO and key |

Environment overrides anything in `lab.conf`. The two you will use:

```bash
LAB_NET=internet ./lab up     # NAT egress for pacman / omarchy update
LAB_VNC_PORT=5910 LAB_NET=internet ./lab up   # a VNC console for a human
```

## The loop

1. **`reset`** — start from a known state, always. The overlay is deleted and
   recreated from golden; nothing from the last experiment survives.
2. **`sync`** — make the guest look like your machine. Default manifest:
   `~/.config/hypr`, `omarchy/shell.json` **and** `omarchy/plugins` (your
   `shell.json` names cloned plugins by id; without their code the shell drops
   part of its plugin graph), `omarchy/extensions`, `ghostty`, `tmux`, `herdr`.
3. **Change it** — `ssh` in, or edit on the host and `sync` again.
4. **`test`** — session alive, `hyprctl reload` and `configerrors` clean,
   bindings loaded, `shell.json` parses and the shell answers IPC, ghostty /
   tmux / herdr configs validate (herdr against upstream's canonical key
   reference, because `herdr config check` accepts anything).
5. **`shot`** — look. A green test says nothing about whether a desktop change
   looks right. Gaps and borders are invisible until two windows are tiled.
6. **`promote`** — one path at a time, backup under
   `promote-backups/<timestamp>/`. `/etc` changes are validated in the guest
   and applied on the host by hand, deliberately.
7. Broke it? **`reset`**. The host was never touched.

When something behaves oddly and you cannot tell whether it is your config or
Omarchy: `reset` and check the pristine guest. It is the same release from the
official ISO, so a defect that reproduces there is upstream's.

## Driving the guest

`keys`, `mouse` and `shot` talk to QEMU's QMP socket, so they work where ssh
cannot: the greeter, the lock screen, the installer, a TTY. The loop is **act,
wait ~3 s, `shot`, read the PNG, decide** — and never type into a screen you
have not looked at. Modelled on
[ThePrimeagen/Oligarchy](https://github.com/ThePrimeagen/Oligarchy); its key
encoding is ported verbatim in `runner/qmp.py` (`qmp.py selftest` runs its
test vectors).

```bash
./lab keys 'echo hi<ENTER>'           # letters as written; "A" is shift+a
./lab keys '<M-ENTER>'                # Super+Enter — Omarchy's terminal binding
./lab keys '<C-A-F3>'                 # TTY 3: focus-proof, survives a dead shell
./lab keys '<Down><Down><ENTER>'      # TUI menus want arrows, not letters
./lab keys --secret "$pw<ENTER>"      # typed; the recorder logs only the length
./lab mouse 0.5 0.5                   # sweep there — Hyprland focuses under it
./lab mouse 0.3 0.2 left 2            # double-click; right, middle, wheel-up/-down
```

Keys: `<ENTER> <ESC> <TAB> <BS> <DEL> <SPACE> <UP> <DOWN> <LEFT> <RIGHT> <HOME>
<END> <PGUP> <PGDN> <F1>..<F24> <LT> <GT>`; modifiers `<C-x>` `<A-x>` `<S-x>`
`<M-x>`, combinable (`<C-S-x>`); bare `<META_L>` taps Super. Mouse coordinates
are fractions: pixel `(px, py)` on a `W×H` shot is `x = px/(W-1)`,
`y = py/(H-1)`.

Every `keys`, `mouse` and `shot` is appended to `run/actions.log` — a flight
recorder for replaying or auditing a drive.

Two behaviours are the way they are because they were measured:

- A chord is one `input-send-event` list (press and release together), not
  `send-key`. Under CPU load the guest's autorepeat fired inside `send-key`'s
  press/release gap and `@` arrived as `@@@@@`.
- A move is a 20-step sweep from the last position, not a warp. Hyprland's
  `follow_mouse` does not refocus on a single absolute warp; it does on a sweep.

## Security model

The guest is treated as hostile: it runs community plugins, synced configs and
whatever an agent was told to try. Before any of this existed, a guest could
open TCP connections to the host's own `sshd` and syncthing over the docker
bridge, to the host's LAN address, and to the internet. Each layer closes one
of those, and each was verified from inside the guest.

**No network unless asked.** The VM container runs with `--network none`: no
interface but loopback, no route, no DNS, enforced by the kernel's namespace
rather than by QEMU. Nothing is published on the host. `ssh` rides a
`docker exec` into the container and from there to qemu's loopback hostfwd, so
there is no socket for anyone else on the host to find. Verified blocked from
inside: host `:22` and `:22000` over the bridge, the host's LAN IP, the slirp
alias `10.0.2.2`, `1.1.1.1:443`, DNS. `LAB_NET=internet` puts the container on
docker's NAT bridge (`https://omarchy.org` → 200) and re-exposes host services
bound on `0.0.0.0` and the LAN — a conscious step down, for a guest you trust.

**A bounded container.** Your uid, `--cap-drop=ALL`, `no-new-privileges`,
read-only rootfs with a 64 MB tmpfs, 512 pids, memory capped at guest RAM plus
2 GB. QEMU gets `/dev/kvm`, two bind mounts and a read-only control-plane
script. A QEMU escape lands somewhere that can do very little.

**Private files.** `images/` (the golden disk, and `cidata.iso` with the
password hash and public key), `run/` (the QMP socket is full control of the
guest), `state/` and `promote-backups/` are mode 700; `cidata.iso` is 600.
Re-applied at every start.

**`promote` distrusts the guest.** `$HOME`-relative paths only, no `..`;
credential stores (`.ssh`, `.gnupg`, `.omp`, `.docker`, `.aws`, `.kube`,
`.password-store`, keyrings, `.config/gh`) refused by name; the archive is
unpacked to a scratch directory and inspected — no symlinks, nothing outside
the requested path — before a byte touches `$HOME`. Verified against a guest
that planted `evil -> /etc` inside a directory and one that symlinked the
target itself.

**`sandbox` is the strong form.** Fresh overlay, isolation forced, and the
container plus overlay deleted on every exit path — normal, failure, Ctrl-C.
For a marketplace plugin, a script from a forum, an agent doing something you
did not review.

**Not covered.** The docker group is root-equivalent on the host and the lab
needs it. `LAB_VNC_PORT` publishes a passwordless console on loopback. A
`tailscale_authkey` in `state/cidata/` deliberately joins the guest to your
tailnet. `sync` puts your real configs inside the guest.

## How it works

- **QEMU in a container.** The host never grows a hypervisor stack. The runner
  image (`runner/Dockerfile`) carries `qemu`, OVMF and `genisoimage`; `/dev/kvm`
  is passed in, so the guest runs at native speed. Same pattern as Omarchy's
  own `omarchy-windows-vm`.
- **Unattended install.** The Omarchy ISO looks for a drive labelled `cidata`
  carrying the configurator's own answer files and skips the wizard. `lab
  cidata` writes them, mirroring the ISO configurator's `full_disk` template
  down to the partition arithmetic. Contract:
  [`manual/51-unattended-installs.md`](https://github.com/omacom/omarchy/blob/quattro/manual/51-unattended-installs.md).
- **Golden + overlay.** The installed disk becomes `golden.qcow2`; the guest
  runs on a qcow2 overlay. `reset` deletes the overlay. `golden` commits the
  overlay into its backing file — never moves it over one.
- **Host-derived identity.** Username (`id -un`), timezone (`timedatectl`) and
  Omarchy version (`omarchy version`) are read at runtime; `lab.conf` holds
  only tunables.
- Graphics are software-rendered: fine for layout, bindings, bar, theming and
  lock-screen work; not for GPU performance.

## Layout

```
lab                     the CLI, one bash file
lab.conf                tunables; every value overridable by environment
runner/Dockerfile       arch + qemu-base + edk2-ovmf + cdrtools
runner/qmp.py           control plane: shot, keys, mouse, ssh proxy, selftest
provision/postinstall.sh  runs in the guest after install, before sealing
sync/manifest           host paths mirrored by `sync`
tests/                  checks that run inside the guest
images/  state/  run/  promote-backups/    gitignored artifacts
```

## Known-red baseline

`./lab test` on a pristine, unsynced guest has one deliberate red:

`40-dotfiles.sh` — Omarchy ships `/usr/share/omarchy/config/herdr/config.toml`
as the user's herdr config, and its `close_workspace = "prefix+shift+k"`
collides with herdr's default `swap_pane_up`. Reproduced on a clean 4.0.2
install and confirmed by keystroke injection: the chord destroys the focused
workspace unconfirmed and never swaps panes. Filed as
[omacom/omarchy#10062](https://github.com/omacom/omarchy/issues/10062). The
red clears after `sync` if the host's herdr config binds `swap_pane_*`
explicitly.

Resolved, kept for the record: `50-locale.sh` used to flag multi-layout
`kb_layout` with no `grp:` option — Omarchy only appends `grp:alts_toggle`
when the *first* layout is non-Latin. Setting `kb_options` alongside
`kb_layout` fixes it.
