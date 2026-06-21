/model opus[1m]
claude --resume 87369342-5631-4e0b-b8bd-c6f8925641a7
ENABLE_LOG_SLOW=1
ENABLE_LOG_SLOW=1 bash scripts/build_installer_img.sh
sudo dd if=/home/david/Hamnix/build/hamnix-installer.img of=/dev/sdb bs=4M status=progress


qemu-system-x86_64 -enable-kvm -cpu host     -bios /usr/share/ovmf/OVMF.fd     -drive file=./build/hamnix-installer.img,format=raw,if=virtio     -m 1G -vga std -serial stdio -no-reboot

