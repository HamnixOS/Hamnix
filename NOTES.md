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
