---
name: project-m16-boot
description: "M16 boot history. Kernel is now elf64-x86-64, higher-half @ 0xffffffff80000000 (commits 406c313 + da065ec). Tests boot via BIOS-GRUB-ISO shim (scripts/_kernel_iso.sh)."
metadata: 
  node_type: memory
  type: project
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

M16 pivot: from "Pynux/Adder as .ko modules inside stock Linux" to "compile our own kernel image." Bare-metal kernel boots, handles interrupts, schedules cooperative kthreads, has printk.

**Current state (2026-05-20+):** elf64-x86-64, higher-half kernel @ `0xffffffff80000000` (PML4 entry 511). LMA/VMA split linker script (low boot region + high-half kernel). QEMU multiboot1 `-kernel` can't load it — boot via BIOS-GRUB-ISO shim.

**Why M16:** the .ko-into-stock-Linux path could never reach a true Linux replacement — boot, MM, scheduler, syscall entry, and module ABI all stay owned by stock Linux.

**Layout** mirrors Linux source tree (`arch/x86/{boot,kernel,mm}/`, `kernel/sched/`, `kernel/printk/`, `mm/memblock`, `drivers/tty/serial/early_8250`, `init/main`).

**Non-obvious invariants:**
- Page tables MUST be outside `[__bss_start, __bss_end)` — head_64.S zeroes BSS with paging on; PT in .bss triple-faults. Use `.pgtables` NOLOAD section.
- DIV codegen is unsigned only (`divq` + `xor %rdx`). Signed division will need a separate codepath.
- `while value > 0` compares signed — use `value != 0` in unsigned loops.
- Per-CPU GSBASE survives context switches (set by setup_per_cpu_areas, not per-task).

## Related
[[project-x86-backend-decision]], [[project-real-hw-boot]]
