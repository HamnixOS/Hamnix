---
name: project-endgame
description: "Hamnix's long-term goal — full Linux ABI (kernel + userspace) + Debian repo + NVIDIA — shippable distribution."
metadata: 
  node_type: memory
  type: project
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

Build toward a real Linux-compatible distribution. Most of the system is Hamnix-authored; userspace long-tail comes from Debian's repos.

**Order (skip none):**

1. **M-series** (M1..M16.x) — DONE/IN-PROGRESS. Bare-metal x86_64 kernel in Adder. Block layer, ext4 r/w, FAT r, VFS, procfs, tmpfs, /dev, RTC, PS/2 kbd, hamsh, ~55 user binaries.

2. **L-series — Linux kernel ABI** — IN PROGRESS. Binary compat with stock Linux 6.1/6.12 .ko modules. Currently loading drivers (e1000e, ahci, nvme, xhci, snd_hda_intel, cfg80211, mac80211, ...) via the L-shim.

3. **U-series — Linux userspace ABI** — NOT STARTED. Run unmodified Linux binaries (Steam, Firefox). Implies ld-linux-x86-64.so.2, glibc syscall ABI, /proc + /sys layout, sysfs/udev, ioctl numbers, PID 1 + sessions + capabilities, futex + CLONE_THREAD, mmap layout.

4. **NVIDIA** — endgame test. Closed-source nvidia.ko + libnvidia-glcore.so all working. Validates both L- and U-series.

5. **Debian repo** — shipping gate. dpkg/apt path, Debian /etc + /lib + /var/lib/dpkg, majority of packages just work.

## Why
Real OS, not hobby kernel. Author keeps security-critical surface (boot/kernel/init/shell), users get the world's largest free-software repo for everything else.

## Discipline
Don't burn bridges to Linux compat:
- FS layout: Linux conventions (/etc /bin /lib /usr /var /tmp /proc /sys /dev)
- New syscalls: high range (1000+) to avoid colliding with Linux 0..400+
- Kernel struct layouts: match Linux's where possible
