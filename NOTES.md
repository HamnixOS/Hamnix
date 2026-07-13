/model opus[1m]
claude --resume 87369342-5631-4e0b-b8bd-c6f8925641a7
ENABLE_LOG_SLOW=1
ENABLE_LOG_SLOW=1 bash scripts/build_installer_img.sh
sudo dd if=/home/david/Hamnix/build/hamnix-installer.img of=/dev/sdb bs=4M status=progress


cd /home/david/Hamnix

# ==== EASIEST: try the live image + install, via the helper ====
# scripts/run_installer.sh sets up OVMF/bootindex/NVMe-target/NIC correctly.
# Without an explicit bootindex on the installer media, OVMF stops auto-booting
# it the moment an NVMe target or NIC is attached and falls to the EFI shell /
# PXE — the helper avoids that. It also attaches a virtio-net NIC by default.

cd /home/david/Hamnix

# Just look at the live desktop (no disk; a GTK window opens):
NO_NET=1 DISK=/tmp/hamnix-live-scratch.qcow2 bash scripts/run_installer.sh
#   (a throwaway target is created but you can ignore it and just use the live DE)

# ---- install to disk + boot from disk ----
# NOTE (2026-07-12): the old installed-boot NX/SMAP fault (#68/#120) is FIXED —
# the ELF loader now STAC/CLAC-brackets its segment writes. Installed disk boots.

# 1) Reuse your existing target disk (or create one):
#    qemu-img create -f qcow2 /tmp/hamnix-disk.qcow2 8G

# 2) Boot the installer WITH the target attached → it AUTO-runs the install
#    (rc.boot sees the NVMe target present and runs /etc/install_nvme.hamsh).
DISK=/tmp/hamnix-disk.qcow2 bash scripts/run_installer.sh
#    Watch it: "install target present -- auto-running /etc/install_nvme.hamsh"
#    then it powers off (--no-reboot). Headless variant for logs:
#    HEADLESS=1 DISK=/tmp/hamnix-disk.qcow2 bash scripts/run_installer.sh

# 3) Boot FROM the installed disk (no installer medium) — bootindex=0 on the NVMe:
qemu-system-x86_64 -enable-kvm -cpu host -m 2G -bios /usr/share/ovmf/OVMF.fd \
  -drive file=/tmp/hamnix-disk.qcow2,format=qcow2,if=none,id=nvmeroot \
  -device nvme,drive=nvmeroot,serial=hamnvme01,bootindex=0 \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -vga std -display gtk -serial stdio
#    (scripts/_installed_boot.sh does the same against a golden disk, for CI.)

# ---- one-liner manual live boot (single disk, no target/NIC) ----
# Works because nothing competes for boot; use a WRITABLE OVMF copy so UEFI can
# persist its boot entry (read-only -bios can fall to the EFI shell):
#   cp /usr/share/ovmf/OVMF.fd /tmp/ovmf.fd
#   qemu-system-x86_64 -enable-kvm -cpu host -m 2G -bios /tmp/ovmf.fd \
#     -drive file=build/hamnix-installer.img,format=raw,if=virtio \
#     -vga std -display gtk -serial stdio


# ==== test GUI apps directly on this Linux HOST (no QEMU, milliseconds) ====
# The browser + hamUI apps are dual-target: their engine compiles for the Linux
# host and renders without booting Hamnix. Fast iteration loop.

cd /home/david/Hamnix

# --- native browser: render an HTML page ---
bash scripts/test_hambrowse_host.sh              # full browser gate (builds build/host/hambrowse_host)
build/host/hambrowse_host /path/to/page.html 100 # render ONE page -> layout dump + JS console
#   e.g. echo '<h1 style="color:navy">hi</h1><script>console.log(1+1)</script>' > /tmp/p.html
#        build/host/hambrowse_host /tmp/p.html 100

# --- JS engine: run a .js file ---
bash scripts/test_jsengine_host.sh
build/host/js_host /path/to/script.js

# --- hamUI scene apps (2048, calculator) -> PNG you can open ---
bash scripts/test_ham2048_host.sh   # writes build/host/2048_before.png / 2048_after.png
bash scripts/test_hamcalc_host.sh   # writes build/host/calc_*.png
xdg-open build/host/2048_after.png
