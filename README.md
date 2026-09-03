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
the ISO plus disks, and `openssl`/`jq`/`ssh-keygen` on the host.
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
./lab reset               # discard the guest, back to golden, in seconds
./lab down                # graceful powerdown
./lab provision           # re-apply guest setup (autologin, test tooling)
./lab golden              # re-seal the current guest state as the revert point
```

GUI access when you want to click around yourself: a VNC console on
`127.0.0.1` at `LAB_VNC_PORT` (see `lab.conf`; `./lab status` prints it).

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
lab                     the CLI (bash, no dependencies beyond docker/ssh/jq)
lab.conf                cpus, memory, disk size, ports, guest identity
runner/Dockerfile       arch + qemu-base + edk2-ovmf + cdrtools
sync/manifest           which production paths `./lab sync` mirrors
tests/                  checks that run inside the guest
images/                 ISO, golden.qcow2, overlay, OVMF vars   (gitignored)
state/                  ssh key, guest password, cidata files    (gitignored)
run/                    qmp socket, serial log, screenshots      (gitignored)
promote-backups/        production files replaced by `promote`   (gitignored)
```

## Notes and limits

- Graphics are software-rendered (`virtio-vga`, no host GPU passthrough), so the
  guest is fine for layout, bindings, bar, theming and lock-screen work, and not
  for GPU performance or Wayland driver behaviour.
- `state/` holds the guest password and the private lab SSH key. It is
  gitignored; keep it that way.
- The guest gets NAT networking with only its SSH port forwarded to
  `127.0.0.1`. Add `state/cidata/tailscale_authkey` before `bootstrap` if you
  want the guest to join the tailnet instead (the ISO supports it natively).
- `./lab destroy` removes the disks but keeps the ISO and SSH key, so a rebuild
  is one `./lab bootstrap` away.

## Known-red baseline

`./lab test` on a *pristine* guest is not all-green, and that is deliberate —
the reds are real findings, not lab defects:

- `40-dotfiles.sh` fails with
  `clashes with live defaults: {'keys.swap_pane_up': 'prefix+shift+k'}`.
  Omarchy ships `/usr/share/omarchy/config/herdr/config.toml` (md5
  `ea3c7a4726c27ed8ef93e8e527662d07`) as the user's herdr config; its
  `close_workspace = "prefix+shift+k"` collides with herdr's own default
  `swap_pane_up`. Reproduced on a clean 4.0.2 install, so it is upstream.
- `50-locale.sh` fails on `kb_layout` whenever the synced host `~/.config/hypr`
  declares several layouts (e.g. `us,ara`) with no `grp:` switch option and no
  `switchxkblayout` binding: every layout after the first is unreachable.
