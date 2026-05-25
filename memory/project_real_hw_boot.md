---
name: project-real-hw-boot
description: "Hamnix boots to userspace on Asus i5-4210U Haswell (BIOS + UEFI confirmed 2026-05-20). Remaining gap: no keyboard input (NOT priority)."
metadata: 
  node_type: memory
  type: project
  originSessionId: 87369342-5631-4e0b-b8bd-c6f8925641a7
---

**Milestone 2026-05-20:** Hamnix reaches `[hamsh] M16.35 shell ready` on real Asus laptop, BOTH Legacy/BIOS and UEFI.

## The triple-fault fix (commit `62e5939`)

15 ISO iterations of ring-3 triple-fault, never reached first user instruction. UD2/HLT at user RIP both silent. Every register dump matched QEMU byte-for-byte.

Three mitigations applied together right after `load_cr3` in `start_first_task`:
1. `fninit` to clear firmware-dirty FPU state
2. Set `CR4.OSXSAVE=1` when CPUID.01h:ECX bit 26 set
3. Clear `RFLAGS.IF` in first-task iret frame + `cli` before sysretq

**Most likely decisive: CR4.OSXSAVE.** Kernel had OSXSAVE=0 on a CPU advertising XSAVE. QEMU TCG reports no XSAVE so never exercised that path — real-hw-only bug.

## Remaining gap

Keyboard input dead on Asus. `[atkbd-diag]` shows `bytes_from_0x60 stays 0`. User explicitly said NOT priority — don't dispatch unless asked.

## Discipline

- Which of the 3 mitigations is decisive isn't bisected yet. Don't remove any without bisecting first on real hw.
- ISO loop: `scripts/build_iso.sh` → user dd's to USB. ~20-30 min wall time. Batch diagnostics.
- M16.151..156 diagnostic scaffolding can be trimmed eventually, but KEEP the trap-diag #UD/#GP/#PF/#DF handlers — useful infrastructure.

## Related
[[project-m16-boot]], [[project-e1000e-ko]]
