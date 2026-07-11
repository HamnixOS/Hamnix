/model opus[1m]
claude --resume 87369342-5631-4e0b-b8bd-c6f8925641a7
ENABLE_LOG_SLOW=1
ENABLE_LOG_SLOW=1 bash scripts/build_installer_img.sh
sudo dd if=/home/david/Hamnix/build/hamnix-installer.img of=/dev/sdb bs=4M status=progress


cd /home/david/Hamnix

qemu-system-x86_64 -enable-kvm -cpu host -m 2G \
-bios /usr/share/ovmf/OVMF.fd \
-drive file=build/hamnix-installer.img,format=raw,if=virtio \
-vga std -display gtk \
-serial stdio


# ---- install to disk + boot from disk ----
# NOTE: install works; booting the installed disk is currently blocked by a
# kernel NX-fault regression (task #68, being fixed). Live image above is fine.

# 1) make a blank 8 GB target disk (once)
qemu-img create -f qcow2 /tmp/hamnix-disk.qcow2 8G

# 2) boot the installer WITH the blank disk attached → it auto-installs
qemu-system-x86_64 -enable-kvm -cpu host -m 2G -bios /usr/share/ovmf/OVMF.fd \
  -drive file=build/hamnix-installer.img,format=raw,if=virtio \
  -drive file=/tmp/hamnix-disk.qcow2,format=qcow2,if=none,id=nvmetgt \
  -device nvme,drive=nvmetgt,serial=hamnvme01 \
  -vga std -display gtk -serial stdio

# 3) after it installs, boot FROM the installed disk (drop the installer medium):
qemu-system-x86_64 -enable-kvm -cpu host -m 2G -bios /usr/share/ovmf/OVMF.fd \
  -drive file=/tmp/hamnix-disk.qcow2,format=qcow2,if=none,id=nvmetgt \
  -device nvme,drive=nvmetgt,serial=hamnvme01,bootindex=1 \
  -vga std -display gtk -serial stdio


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
