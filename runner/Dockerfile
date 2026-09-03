# QEMU lives in a container so the production host never grows a hypervisor
# stack. /dev/kvm is passed in, so the guest still runs at native speed.
# This mirrors how Omarchy itself ships its Windows VM (omarchy-windows-vm).
FROM archlinux:base

RUN pacman -Sy --noconfirm --needed \
      qemu-base \
      qemu-hw-display-virtio-vga \
      qemu-hw-display-virtio-gpu \
      qemu-hw-display-virtio-gpu-pci \
      edk2-ovmf \
      cdrtools \
      openssh \
      socat \
      jq \
      python \
  && pacman -Scc --noconfirm \
  && rm -rf /var/cache/pacman/pkg/*

# qemu writes screenshots and sockets here; the host bind-mounts both.
RUN mkdir -p /images /labrun

ENTRYPOINT ["/bin/bash", "-c"]
