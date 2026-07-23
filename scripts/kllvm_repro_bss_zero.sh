#!/usr/bin/env bash
# scripts/kllvm_repro_bss_zero.sh — Phase-5k reproduction + instrumentation harness
# for the LLVM-kernel "execve->first-fault multi-global BSS zeroing" wall.
#
# WHAT PHASE 5k ESTABLISHED (docs/kernel_llvm_phase5b.md):
#   * The stage-01 wall of Phases 5b-5j is a DEBUG-PROBE LAYOUT ARTIFACT: a
#     CLEAN (probe-free) do_page_fault-LLVM kernel boots PAST stage-01 to
#     `rfork: child created, pid=7` under BOTH TCG and KVM.  Adding even one
#     BSS probe global shifts .bss so the wild store lands on task_table[6]/
#     printk_line_seq/vma_tree_root -> the stage-01 SIGSEGV.
#   * The zeroing is GENUINE PHYSICAL memory (confirmed CR3-independently with
#     the QEMU monitor `xp` physical read), not a per-CR3 mapping artifact.
#     KPTI is gated OFF (kpti_live=0) so #PF does not switch CR3.
#   * It is a DETERMINISTIC CPU STORE, not device DMA: `-nic none` (removing the
#     default e1000) does NOT stop it, and the default `pc` machine has no other
#     active-DMA device post-boot.  It is the layout-sensitive wild OOB store in
#     SHARED LLVM code (Phase 5g), and it is NOT a constant-offset OOB
#     (scripts/scan_oob.py = 0 on the current .ll) -> a variable-index / stride
#     miscompile that constant-offset scanning cannot see.
#
# TOOLING REALITY (save the next agent the dead-ends):
#   * Hardware watchpoints are USELESS here.  TCG deopts too slow to reach the
#     late event; the KVM gdbstub DR watchpoints are clobbered by the kernel's
#     own DRn writes early in boot (they miss even the legit execve store of
#     task_table[6].image_lo=0x400000).
#   * The productive instruments are: (a) a MINIMAL +1-global source probe at
#     do_page_fault entry to read the victims (this file drives that), (b) the
#     QEMU monitor `xp <phys>` CR3-independent physical read, and (c) the
#     clean-vs-probe and `-nic none`/device-quiesce A/B.
#
# USAGE:
#   scripts/kllvm_repro_bss_zero.sh build/kllvm/hamnix_kernel_llvm.elf
# Boots the ELF (do_page_fault must be LLVM: build with KLLVM_DEFAULT_FORCE_NATIVE="")
# under KVM with the default NIC removed and prints the boot outcome.  If the
# ELF carries a `[zprobe] dpf entry ... img=0x0` line, the victims were zeroed.
set -uo pipefail
ELF="${1:-build/kllvm/hamnix_kernel_llvm.elf}"
[ -f "$ELF" ] || { echo "no ELF: $ELF" >&2; exit 1; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/boot/grub"
cp "$ELF" "$WORK/boot/hamnix.elf"
printf 'set timeout=0\nset default=0\nmenuentry "H" {\n multiboot /boot/hamnix.elf\n boot\n}\n' \
    > "$WORK/boot/grub/grub.cfg"
ISO="$WORK/k.iso"
grub-mkrescue -o "$ISO" "$WORK" >/dev/null 2>&1 || { echo "grub-mkrescue failed" >&2; exit 1; }
SER="$WORK/serial.log"; : > "$SER"
ACC=(-accel tcg); [ -r /dev/kvm ] && [ -w /dev/kvm ] && ACC=(-accel kvm -cpu host)
/usr/bin/qemu-system-x86_64 "${ACC[@]}" -m 1024M -cdrom "$ISO" -boot d \
    -no-reboot -display none -monitor none -serial file:"$SER" -nic none >/dev/null 2>&1 &
QP=$!
# run until the child fault (zprobe), the stage-01 wall, or a fixed budget
for _ in $(seq 1 40); do
    grep -aqE 'zprobe|tree-find|pid=7|SIGSEGV' "$SER" 2>/dev/null && break
    kill -0 $QP 2>/dev/null || break
    sleep 2
done
sleep 2; kill $QP 2>/dev/null
echo "=== outcome ($(wc -l <"$SER") serial lines) ==="
grep -anE 'stage-0|shell ready|device binds|pid=7|zprobe|tree-find|SIGSEGV' "$SER" | tail -12
