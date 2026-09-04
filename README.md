# Omarchy lab

A disposable Omarchy VM for testing desktop/system changes before they touch
your real machine. Install once, then revert to a known-good state in
seconds, as often as you like.

## Why it is built this way

- **QEMU runs in a container.** The host never grows a hypervisor stack: no
  `qemu`, `libvirt` or `virt-manager` packages are installed on it. The runner
  image (`runner/Dockerfile`) carries them, gets `/dev/kvm` passed in, and runs
  at native speed. This is the same pattern Omarchy itself uses for
  `omarchy-windows-vm`.
- **Unattended install, no keyboard.** The Omarchy ISO looks for a second drive
  labelled `cidata`; when it finds the configurator's own answer files there it
  skips the wizard, installs, and reboots. `./lab cidata` generates that drive.
  Contract: [`manual/51-unattended-installs.md`](https://github.com/omacom/omarchy/blob/quattro/manual/51-unattended-installs.md).
- **Golden snapshot + overlay.** After the install, the disk becomes
  `images/golden.qcow2` (read-only in practice) and the guest runs on a qcow2
  overlay. `./lab reset` deletes the overlay and recreates it — a full revert
  costs a second and no reinstall.
- **Same username as the host.** `LAB_USER` defaults to `id -un`, so every path
  under `~/.config` matches and configs move between host and guest without
  rewriting. The guest's Omarchy release defaults to the host's, too.

## Prerequisites

`/dev/kvm` readable and writable by your user, Docker access, ~70 GB free for
the ISO plus disks, and on the host: `ssh`, `ssh-keygen`, `curl`, `openssl`,
`jq`, `tar`, `sha256sum`, `timedatectl` — all stock on Arch/Omarchy.
`./lab doctor` checks all of it.

## First run

```bash
./lab doctor        # prerequisites
./lab build         # build the qemu runner image (~230 MB)
./lab fetch-iso     # download + sha256-verify the Omarchy ISO (5.8 GB)
./lab bootstrap     # unattended install, then seal the golden snapshot
```

`bootstrap` boots the VM with the Omarchy ISO plus the generated `cidata` drive,
waits for the guest to install itself and reboot, waits for its `sshd`,
provisions autologin, then seals the snapshot. The ISO carries its own
packages, so this is an offline install: measured at ~4.5 minutes on 6 vCPUs.
Watch it:

```bash
./lab logs 60       # guest serial console
./lab shot boot     # PNG screenshot of the guest display
```

The guest's login password is generated and stored in `state/vm_password`
(mode 0600). SSH uses the dedicated key in `state/id_ed25519`; the ISO installs
it as the guest user's `authorized_keys` and enables `sshd` for it.

## Daily use

```bash
./lab up                  # start the VM (or ./lab reset for a clean guest)
./lab status              # container, snapshot, overlay, guest identity
./lab ssh                 # interactive shell in the guest
./lab ssh 'omarchy version'
./lab sync                # push production configs (sync/manifest) into guest
./lab test                # run tests/ inside the guest
./lab shot after-change   # visual proof -> run/shots/after-change.png
./lab keys "<M-ENTER>"    # type into the guest over QMP (see "Driving the guest")
./lab mouse 0.25 0.5 left # sweep the pointer there and click
./lab reset               # discard the guest, back to golden, in seconds
./lab down                # graceful powerdown
./lab provision           # re-apply guest setup (autologin, test tooling)
./lab golden              # re-seal the current guest state as the revert point
```

GUI access when you want to click around yourself: a VNC console on
`127.0.0.1` at `LAB_VNC_PORT` (see `lab.conf`; `./lab status` prints it).

## Driving the guest

`keys`, `mouse` and `shot` talk to QEMU's QMP socket, so they work wherever
SSH cannot: the greeter, the lock screen, the installer, a TTY. Together they
are the loop an agent (or you, blind) runs: **act, wait ~3 s, `shot`, read the
PNG, decide.** Never type into a screen you have not looked at. This part is
modelled on [ThePrimeagen/Oligarchy](https://github.com/ThePrimeagen/Oligarchy),
whose key encoding is ported verbatim (`runner/qmp.py`) and whose field guide
is worth reading before a long drive.

```bash
./lab keys 'echo hi<ENTER>'           # letters as written; "A" is shift+a
./lab keys '<M-ENTER>'                # Super+Enter: Omarchy's terminal binding
./lab keys '<C-A-F3>'                 # TTY 3 — focus-proof, survives a dead shell
./lab keys '<Down><Down><ENTER>'      # TUI menus want arrows, not letters
./lab keys --secret "$pw<ENTER>"      # typed, but the recorder logs only its length
./lab mouse 0.5 0.5                   # move (a sweep): Hyprland focuses under it
./lab mouse 0.3 0.2 left 2            # double-click; right, middle, wheel-up/-down too
```

Encoding: `<ENTER> <ESC> <TAB> <BS> <DEL> <SPACE> <UP> <DOWN> <LEFT> <RIGHT>
<HOME> <END> <PGUP> <PGDN> <F1>..<F24> <LT> <GT>`; modifiers `<C-x>` ctrl,
`<A-x>` alt, `<S-x>` shift, `<M-x>` meta, combinable as `<C-S-x>`; a bare
`<META_L>` taps Super. Mouse coordinates are fractions of the screen
(`0` top/left, `1` bottom/right): pixel `(px, py)` on a `W×H` shot is
`x = px / (W - 1)`, `y = py / (H - 1)`.

Two behaviours were measured rather than assumed, and the code says why:

- Key chords go out as one `input-send-event` list (press + release), not
  `send-key`. Under CPU load the guest's own autorepeat fired between a
  `send-key` press and its delayed release — `@` arrived as `@@@@@`. Atomic
  chords typed three 90-character lines identically under eight CPU burners.
- A pointer move is a 20-step sweep from the last position, not a warp. A
  single absolute warp moves the cursor but Hyprland 0.56's `follow_mouse`
  never refocuses on it; the sweep does, every time.

Every `keys`, `mouse` and `shot` is appended to `run/actions.log` with a
timestamp — a flight recorder for replaying or auditing a drive. Use
`keys --secret` for anything you would not want in that file.

## The workflow this exists for

1. `./lab reset` — start from a pristine Omarchy.
2. `./lab sync` — mirror your real `~/.config/hypr`, `shell.json`, terminal,
   tmux and herdr configs into the guest.
3. Make the change in the guest (`./lab ssh`, or edit and re-`sync`).
4. `./lab test` — automated checks: session alive, `hyprctl reload` +
   `configerrors` clean, bindings loaded, `shell.json` parses and the shell
   answers IPC, ghostty/tmux/herdr configs validate.
5. `./lab shot` — look at the result, since a desktop change is only really
   verified visually.
6. `./lab promote .config/hypr/bindings.lua` — copy the verified file back to
   production. Every promotion first copies the current production file to
   `promote-backups/<timestamp>/<path>`.
7. Broke the guest instead? `./lab reset`. The host was never touched.

## Layout

```
lab                     the CLI (bash + stock host tools: docker, ssh, curl, openssl, jq, tar)
lab.conf                cpus, memory, disk size, ports, guest identity
runner/Dockerfile       arch + qemu-base + edk2-ovmf + cdrtools
runner/qmp.py           QMP control plane: keys, mouse, shot (bind-mounted, no rebuild)
sync/manifest           which production paths `./lab sync` mirrors
tests/                  checks that run inside the guest
images/                 ISO, golden.qcow2, overlay, OVMF vars   (gitignored)
state/                  ssh key, guest password, cidata files    (gitignored)
run/                    qmp socket, serial log, screenshots, actions.log (gitignored)
promote-backups/        production files replaced by `promote`   (gitignored)
```

## Notes and limits

- Graphics are software-rendered (`virtio-vga`, no host GPU passthrough), so the
  guest is fine for layout, bindings, bar, theming and lock-screen work, and not
  for GPU performance or Wayland driver behaviour.
- `state/` holds the guest password and the private lab SSH key. It is
  gitignored; keep it that way.
- The guest gets NAT networking. Two host ports on `127.0.0.1` reach it: SSH
  (key-only) and the VNC console, which has no password — anyone with a local
  account on the host can drive the autologged-in guest through it. Add
  `state/cidata/tailscale_authkey` before `bootstrap` if you want the guest on
  the tailnet instead (the ISO supports it natively).
- `./lab destroy` removes the disks but keeps the ISO and SSH key, so a rebuild
  is one `./lab bootstrap` away.

## Known-red baseline

`./lab test` on a *pristine, unsynced* guest is not all-green, and that is
deliberate — the red is a real finding, not a lab defect:

- `40-dotfiles.sh` fails with
  `clashes with live defaults: {'keys.swap_pane_up': 'prefix+shift+k'}`.
  Omarchy ships `/usr/share/omarchy/config/herdr/config.toml` (md5
  `ea3c7a4726c27ed8ef93e8e527662d07`) as the user's herdr config; its
  `close_workspace = "prefix+shift+k"` collides with herdr's own default
  `swap_pane_up`, which is then unreachable by any chord. Reproduced on a clean
  4.0.2 install and confirmed by keystroke injection in the guest — the chord
  destroys the focused workspace and every pane in it, unconfirmed
  (`confirm_close = false`), and never swaps panes. Filed upstream as
  [omacom/omarchy#10062](https://github.com/omacom/omarchy/issues/10062).
  The red disappears after `./lab sync` if the host's own herdr config binds
  `swap_pane_*` explicitly.

Fixed since, so no longer red:

- `50-locale.sh` used to fail on `kb_layout` when the synced host config
  declared several layouts (e.g. `us,ara`) with no `grp:` switch option: every
  layout after the first was unreachable, because Omarchy only appends
  `grp:alts_toggle` when the *first* layout is non-Latin
  (`default/hypr/input.lua`). Setting `kb_options` explicitly alongside
  `kb_layout` fixes it; verified in the guest, then promoted to the host.
