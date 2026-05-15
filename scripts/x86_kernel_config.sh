#!/usr/bin/env bash
# Apply the Pynux M1 kernel configuration to a kernel source tree.
#
# Starts from `make defconfig` and disables the x86 mitigations that the
# Pynux x86_64 backend does not yet emit code for, while enabling the
# serial console + module loading that the QEMU dev loop needs.
#
# Usage: x86_kernel_config.sh <kernel-source-dir>
#
# Mitigations are OFF for initial M1 development; they get ratcheted back
# on as the codegen matures (see docs/x86-backend.md and the project brief).
set -euo pipefail

KSRC="${1:?usage: x86_kernel_config.sh <kernel-source-dir>}"
cd "$KSRC"

echo "[config] make defconfig"
make defconfig >/dev/null

cfg() { ./scripts/config "$@"; }

echo "[config] disabling x86 mitigations (M1: codegen not ready for them)"
cfg --disable X86_KERNEL_IBT
cfg --disable CFI_CLANG
cfg --disable RETPOLINE
cfg --disable MITIGATION_RETPOLINE
cfg --disable MITIGATION_RETHUNK
cfg --disable MITIGATION_SLS
cfg --disable RANDOMIZE_BASE          # KASLR off: stable addresses for debugging

echo "[config] enabling module loading (unsigned)"
cfg --enable  MODULES
cfg --enable  MODULE_UNLOAD
cfg --enable  MODULE_FORCE_UNLOAD
cfg --disable MODVERSIONS             # avoid symbol-version friction for M1
cfg --disable MODULE_SIG              # allow unsigned modules
cfg --disable MODULE_SIG_FORCE

echo "[config] enabling serial console + initramfs boot"
cfg --enable  SERIAL_8250
cfg --enable  SERIAL_8250_CONSOLE
cfg --enable  PRINTK
cfg --enable  TTY
cfg --enable  BLK_DEV_INITRD
cfg --enable  BINFMT_ELF
cfg --enable  BINFMT_SCRIPT

echo "[config] make olddefconfig (resolve dependencies)"
make olddefconfig >/dev/null

echo "[config] done. Verifying key symbols:"
for sym in X86_KERNEL_IBT MITIGATION_RETPOLINE MITIGATION_RETHUNK \
           MODULES SERIAL_8250_CONSOLE BLK_DEV_INITRD; do
    printf '  %-24s ' "$sym"
    ./scripts/config --state "$sym" 2>/dev/null || echo "(unknown)"
done
