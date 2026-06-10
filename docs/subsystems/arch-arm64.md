# Architecture: AArch64

> **Source of truth:** `arch/arm64/boot.S`, `arch/arm64/vectors.S`,
> `arch/arm64/kmain.ad`, `arch/arm64/kernel.lds`
> **Last verified against source:** 2026-06-10

## Purpose

The in-progress AArch64 port. It boots on QEMU `virt` to an
interrupt-driven kernel and drops to EL0 userspace. Adder's AArch64
backend (`adder/compiler/codegen_arm64.py`) emits the kernel from the
same `.ad` source; this directory holds the four machine-specific files.

The real-HW target is a Pinebook Pro (RK3399: A72+A53 big.LITTLE, 8250
UART, GICv2). The intent is a board-abstraction layer while keeping
qemu-virt green (see project memory).

## Key files

| Path | Role |
|--|--|
| `boot.S` | boot stub: set up a stack, branch to `kmain()` |
| `vectors.S` | EL1 exception vector table (installed via `VBAR_EL1`); IRQ + sync entries |
| `kmain.ad` | the Adder kernel: UART banner, MMU, GICv2, generic timer, EL0 drop, syscall dispatch |
| `kernel.lds` | linker script |

## Architecture & data structures

`kmain()` (`arch/arm64/kmain.ad`) bring-up sequence, per the file header:

1. Banner over the PL011 UART (MMIO `@0x09000000`).
2. Minimal identity-mapped MMU: 1 GiB block descriptors — device region
   `@0x00000000`, RAM `@0x40000000` — then enable.
3. Install the EL1 vector table (`VBAR_EL1`) and init GICv2
   (distributor `@0x08000000`, CPU interface `@0x08010000`).
4. Program the ARM generic **virtual** timer (PPI INTID 27) for a
   periodic tick; unmask IRQs.
5. Spin in `WFI`; each timer IRQ calls `arm64_irq_handler()`.
6. Drop to EL0: hand-emit a tiny AArch64 user routine into an EL0-
   accessible 2 MiB window, program `SPSR_EL1` (EL0t), `ELR_EL1`,
   `SP_EL0`, then `eret`. The EL0 routine does `write(1, msg, len)` then
   `exit(0)` via `svc #0`. Each `svc` traps to the "Lower EL using
   AArch64" synchronous vector, which saves the GPR frame and calls
   `arm64_sync_handler()`: it reads `ESR_EL1.EC` to confirm SVC and
   services the syscall.

## Entry points

- `kmain()` (`kmain.ad`) — kernel entry from `boot.S`.
- `arm64_irq_handler()` — called from the IRQ vector in `vectors.S`.
- `arm64_sync_handler()` — SVC/syscall dispatcher from the sync vector.

## Invariants & gotchas

- This is a port-in-progress: the EL0 userland here is a hand-emitted
  smoke routine, not the full Plan-9 namespace/VFS stack the x86_64 path
  runs. Keep qemu-virt booting when extending it.
- MMIO addresses above are the QEMU `virt` map; real hardware (Pinebook
  Pro / RK3399) differs — that delta is what the board-abstraction layer
  is for.

## Related docs

- [arch-x86.md](arch-x86.md) — the mature counterpart with the full stack.
- [adder-compiler.md](adder-compiler.md) — the AArch64 codegen backend.
