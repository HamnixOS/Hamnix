# Hamnix Linux ABI Target

**Linux kernel version:** 6.12.48 LTS
**Source tree:** https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
**Tag:** `v6.12.48`
**Architecture:** x86_64 only

## Rationale

Hamnix's M-series tracks (M1..M15 .ko modules) were built against
Linux 6.12 headers and tested on a 6.12 kernel. M13.1's utsname
reader prints "6.12.48". Pinning to this exact point release means:

1. M1..M15 .ko binaries are first-class test artifacts for the L-track.
2. Stock Ubuntu 6.12 distro modules (xhci_hcd, nvme, usbhid, e1000e)
   are loadable without per-version compatibility shims.
3. The struct layouts in `linux_abi/structs/` (generated from this
   version's BTF) are stable and reproducible.

## Out of scope

- Other Linux versions (6.x, 5.x, 4.x — all different ABIs)
- ARM / aarch64
- Module signing (`CONFIG_MODULE_SIG`)
- Tracepoint / ftrace / eBPF
- Live patching / kpatch

## How to refresh

When the project decides to advance to a newer LTS:

1. Update this file with the new version + tag.
2. Re-run `scripts/gen_linux_abi.py` against the new vmlinux's BTF.
3. Commit the regenerated `linux_abi/structs/*.py`.
4. Re-validate the M1..M15 .ko artifacts against the new headers.
5. Bump M13.1's utsname expectation.

Hamnix never ships compatibility shims for old Linux versions —
"pin and forward-port" is the discipline.
