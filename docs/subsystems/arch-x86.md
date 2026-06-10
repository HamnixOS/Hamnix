# Architecture: x86_64

> **Source of truth:** `arch/x86/boot/`, `arch/x86/kernel/`,
> `arch/x86/mm/`, `arch/x86/lib/`, `arch/x86/realmode/`
> **Last verified against source:** 2026-06-10

## Purpose

All x86_64-specific machine setup: UEFI entry, the long-mode boot path,
the IDT/IRQ/syscall plumbing, the PIT/APIC/TSC timekeeping, SMP AP
bringup, the context-switch asm, and the page-table primitives. Hamnix
is **UEFI-only** on x86_64 (no BIOS/GRUB path).

## Key files

### Boot (`arch/x86/boot/`)

| Path | Role |
|--|--|
| `efi_stub.S` | EFI stub that firmware loads; loads kernel + (installer) squashfs into RAM |
| `header.S` | image header |
| `uefi_entry.ad` | UEFI entry in Adder: BootServices, GOP framebuffer, memory map, ExitBootServices |

### Kernel asm + setup (`arch/x86/kernel/`)

| Path | Role |
|--|--|
| `head_64.S` | long-mode entry; zeroes BSS; calls `start_kernel_asm_entry` |
| `idt.ad` / `idt_asm.S` | IDT build + interrupt stubs (`idt_init`) |
| `traps.ad` / `trap_asm.S` / `trap_diag.ad` | exception handlers (`do_trap`), `#PF`, diagnostics |
| `irq.ad` / `irq_asm.S` | IRQ dispatch (`do_irq`), UART-RX IRQ, reschedule/stop IPIs |
| `i8259.ad` | legacy PIC init/disable |
| `apic.ad` | local APIC / IO-APIC |
| `time.ad` | PIT @ 100 Hz, TSC calibration, jiffies, monotonic ns |
| `syscall.ad` / `syscall_64.S` | the native syscall dispatch (`do_syscall`) + SYSCALL/SYSRET entry |
| `sched_asm.S` | `__switch_to_asm` register/rsp context switch |
| `smp.ad` / `smp_asm.S` | MADT-driven AP bringup, per-CPU `%gs` |
| `setup_percpu.ad` / `setup_percpu_asm.S` | per-CPU areas, `get_cpu_id` |
| `tss_asm.S` | per-CPU TSS / RSP0 |
| `module.ad` | in-kernel `.ko` loader hooks (see [kernel-modules.md](kernel-modules.md)) |
| `power.ad` | ACPI S5 poweroff / reset / triple-fault reboot |
| `e820.ad` | physical memory map parse |
| `efi_runtime.ad` | EFI runtime services |
| `vdso_image.S` / `sigret_asm.S` | vDSO blob, signal-return trampoline |
| `kernel.lds` | linker script (higher-half `0xffffffff80000000`) |

### MM, lib, realmode

| Path | Role |
|--|--|
| `arch/x86/mm/init.ad` | `mem_init()` (see [memory.md](memory.md)) |
| `arch/x86/mm/pgtable.ad` | PML4/PDPT/PD/PT primitives, write-combine |
| `arch/x86/mm/module_map.ad` | high-VA window for module text |
| `arch/x86/lib/string_64.S` | optimized memcpy/memset |
| `arch/x86/realmode/trampoline.S` | AP startup trampoline (16-bit → long mode) |

## Architecture & data structures

Boot flow: firmware → `efi_stub.S` → `uefi_entry.ad` (GOP fb + memory
map + ExitBootServices) → `head_64.S` (BSS zero) →
`start_kernel_asm_entry` → `start_kernel()` in `init/main.ad`
(see [kernel-sched.md](kernel-sched.md) for the call order).

The kernel is `elf64-x86-64`, linked higher-half at
`0xffffffff80000000` (`kernel.lds`). Codegen honors SysV AMD64, 16-byte
stack alignment, `ENDBR64` for IBT, no red zone, RIP-relative `.rodata`
(see [../x86-backend.md](../x86-backend.md)).

SMP: `smp.ad` reads the ACPI MADT, starts each AP through the realmode
trampoline, sets up per-CPU `%gs`/TSS, and gives the AP its own per-CPU
runqueue. Idle APs HLT and are woken by a reschedule IPI (tickless); the
old MWAIT-on-jiffies idle hack is gone.

## Entry points

- `start_kernel_asm_entry` (`head_64.S`) → `start_kernel()` (`init/main.ad`).
- `idt_init()` (`idt.ad`) — install the IDT.
- `do_trap()` / `do_irq()` (`traps.ad` / `irq.ad`) — common exception/IRQ handlers.
- `do_syscall()` (`syscall.ad`) — native Layer-1 syscall dispatch (see [plan9-namespace.md](plan9-namespace.md), [linux-abi.md](linux-abi.md)).
- `time_init()` / `get_jiffies()` / `tsc_monotonic_ns()` (`time.ad`).
- `__switch_to_asm` (`sched_asm.S`) — context switch.

## Invariants & gotchas

- UEFI-only. Do not add a BIOS path; `build_iso.sh` is a thin shim over
  the installer image.
- `__switch_to_asm` depends on `TaskStruct.sp` at offset 0 (see
  [kernel-sched.md](kernel-sched.md)).
- ACPI SCI polarity: QEMU's MADT declares the SCI active-HIGH/level (not
  the spec active-low) — honor the MADT override or the power button
  pegs the fan (a documented NUC fix).
- The MADT/per-CPU TSS/IPI entry path from CPL3 is historically fragile
  (documented triple-fault regressions); treat IRQ-from-userspace entry
  changes carefully.

## Related docs

- [arch-arm64.md](arch-arm64.md) — the AArch64 counterpart.
- [memory.md](memory.md), [kernel-sched.md](kernel-sched.md).
- [../BOOT.md](../BOOT.md), [../REAL_HARDWARE.md](../REAL_HARDWARE.md), [../x86-backend.md](../x86-backend.md).
