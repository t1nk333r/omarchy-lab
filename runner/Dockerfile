# QEMU lives in a container so the production host never grows a hypervisor
# stack. /dev/kvm is passed in, so the guest still runs at native speed.
# This mirrors how Omarchy itself ships its Windows VM (omarchy-windows-vm).
FROM archlinux:base

# -Syu, not -Sy: installing from a fresher database than the image's libraries
# is a partial upgrade, which Arch does not support.
RUN pacman -Syu --noconfirm --needed \
      qemu-base \
      qemu-hw-display-virtio-vga \
      qemu-hw-display-virtio-gpu \
      qemu-hw-display-virtio-gpu-pci \
      edk2-ovmf \
      cdrtools \
      python \
  && pacman -Scc --noconfirm \
  && rm -rf /var/cache/pacman/pkg/*

# qemu writes screenshots and sockets here; the host bind-mounts both.
RUN mkdir -p /images /labrun

ENTRYPOINT ["/bin/bash", "-c"]
