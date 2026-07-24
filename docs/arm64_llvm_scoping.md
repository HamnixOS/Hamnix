# ARM64 (AArch64) LLVM Retarget — Scoping Spike

Status: **SCOPING SPIKE / feasibility PoC** (main @ 731f39b9). No compiler code
changed. This document answers one question for the user: is ARM64 a **near-term
LLVM retarget** (mostly free, ride the existing `.ll` emitter) or a **larger
bringup**? Evidence below.

**Verdict (one line):** ARM64 user-mode Adder-via-LLVM is **proven working
today** (real program runs under `qemu-aarch64`, byte-identical output to
x86_64). The **freestanding kernel** is a **bounded bringup**, not a rewrite:
the structured LLVM IR is already target-independent; the entire delta is
concentrated in **~52 inline-asm sites + 236 `%gs`-percpu accesses + the 22
`arch/x86/*.S` boot stubs + linker script**. All quantified below.

---

## 1. PoC — a real Adder program runs on ARM64 via LLVM

**Toolchain (all present on this host — nothing to install):**

| tool | status |
|------|--------|
| `clang-19` | present, cross-compiles to `aarch64` out of the box |
| `qemu-aarch64` / `qemu-aarch64-static` | present (user-mode) |
| `aarch64-linux-gnu-{as,ld,objdump,...}` (binutils 2.44) | present |
| `/usr/aarch64-linux-gnu` sysroot | **binutils only — NO aarch64 libc/crt** |
| `qemu-efi-aarch64` (AAVMF UEFI firmware) | present (for future system-mode boot) |

The missing aarch64 libc is a **non-issue** for the PoC (and for Hamnix in
general): Hamnix is freestanding / Plan-9-native and does not link glibc. The
PoC builds a **static `-nostdlib` ELF** with a tiny per-arch `_start`.

**Method (`scripts/arm64_llvm_poc.sh`):** emit ONE `.ll` from
`tests/bench/llvm/whole_prog.ad` with the existing `host_ac.elf --backend=llvm`,
then compile that **same `.ll`** for BOTH targets and run both. The `.ll` is
100% the compiler's real output; the only aarch64 edits are the **two lines a
retargeted `ssa_llvm.ad` would itself emit differently**, applied by `sed` over
the generated file (NOT a compiler change):

1. `target triple = "x86_64-pc-linux-gnu"` → `"aarch64-unknown-linux-gnu"`
2. the one `__syscall3` inline-asm line
   `asm "syscall", "={rax},{rax},{rdi},{rsi},{rdx},..."` →
   `asm "svc #0", "={x0},{x8},{x0},{x1},{x2},~{memory}"` with the Linux write
   number remapped (x86 `1` → arm64 `64`).

`whole_prog.ad` runs gcd/lcm/prime-count/fib/collatz/sieve/6-arg-call and prints
the accumulator via `print_u64` (which now compiles fully in-subset —
`funcs=10 emitted=10 bailed=0` — so the emitted `.ll` DID contain the raw
`syscall`, exercising delta #2 for real).

**Result — PASS:**

```
x86_64 (native)          stdout=[16834] rc=194   sha256[:16]=702b7185d5376ccf
aarch64 (qemu-aarch64)   stdout=[16834] rc=194   sha256[:16]=702b7185d5376ccf
RESULT: PASS — identical output across x86_64 and aarch64 from the SAME emitted .ll
```

`16834 = 21+42+168+6765+111+9592+135` (gcd+lcm+π(1000)+fib(20)+collatz(27)+
sieve(1e5)+blend6); rc `194 = 16834 & 255`. The aarch64 ELF is a genuine
`ELF 64-bit LSB executable, ARM aarch64, statically linked` running under
`qemu-aarch64`. **A real Adder program, compiled through the Adder LLVM backend,
runs correctly on AArch64.**

Reproduce: `bash scripts/arm64_llvm_poc.sh`

---

## 2. x86-ism inventory for the KERNEL `.ll`

Built the whole-kernel closure with the existing emitter (inspection only, no
ssa file touched, so the host_ac rebuild gotcha does not apply):

```
host_ac.elf --backend=llvm --target=x86_64-bare-metal init/main.ad kernel_main.ll
; ADDER_STAT funcs=11064 emitted=11059 bailed=5     (33.6 MB of IR)
```

**Empirical breakage test.** Swapped only the triple to `aarch64-unknown-none-elf`
and ran `clang-19 --target=aarch64-none-elf -c` on the 33 MB `.ll`. Result:
**186 errors, ALL inline-asm** (`<inline asm>: error: unrecognized instruction
mnemonic / invalid operand / unknown token` — i.e. x86 mnemonics fed to the
aarch64 assembler). **Zero errors came from the structured IR** — every
`define`, `load`/`store`, `getelementptr`, `inttoptr`, `phi`, `br`, `call`,
arithmetic, and global compiled cleanly for aarch64. This is the core finding:
**the IR body is already target-independent; 100% of the hard failures are the
inline-asm sites.**

### 2a. Inline-asm sites — 52 total, categorized

| category | sites | distinct | class | AArch64 equivalent |
|----------|------:|---------:|-------|--------------------|
| `hlt` | 17 | 1 | **(b) trivial** | `wfi` |
| `cli` | 6 | 1 | **(b) trivial** | `msr daifset, #2` |
| `sti` | 1 | 1 | **(b) trivial** | `msr daifclr, #2` |
| `pause` | 4 | 1 | **(b) trivial** | `yield` |
| `mfence` | 2 | 1 | **(b) trivial** | `dmb ish` |
| indirect tail-call trampolines `popq %rbp; jmpq *rN` (one per GPR + a `%r11` variant) | 14 | 14 | **(b) mechanical** | `ldp`/frame-restore + `br xN` |
| `cpuid` feature probe (2 variants: `cpuid_eax`/`ci_eax`) | 2 | 2 | **(b) real work** | `mrs` on `ID_AA64*` regs — different mechanism |
| `rdrand`/`rdseed` HW RNG retry loops | 2 | 2 | **(b) real work** | `mrs RNDR/RNDRRS` (ARMv8.5) or alt entropy |
| 128-bit `mulq` (tls_mul128) | 1 | 1 | **(b) easy** | `mul` + `umulh` (or lower via i128 in IR) |
| `s3_save` register-save (ACPI S3 suspend) | 1 | 1 | **(c) bringup** | PSCI `CPU_SUSPEND`; stub for MVP |
| `lidt … ; int3` (triple-fault-style reset via null IDT) | 1 | 1 | **(c) bringup** | PSCI `SYSTEM_RESET` |

Rollup: **30 sites are trivial 1:1 barriers/wait** (5 distinct mnemonics),
**14 are mechanical** indirect-branch trampolines, **8 are real ARM work**
(cpuid/rng/mul128/suspend/reset — mostly small and mostly stub-able for a first
boot). **There is no `syscall` inline-asm in the kernel `.ll` (count = 0)** —
the freestanding kernel issues no Linux syscalls (those live only in the
`linux_abi` shim), so the syscall-number ABI mismatch is a **user-mode-only**
concern.

### 2b. `%gs` per-CPU (`addrspace(256)`) — 236 sites — THE load-bearing item

The emitter models x86 per-CPU storage as `addrspace(256)` pointers (clang's
`%gs` model): 236 load/store sites. **Isolated test on aarch64:** clang
compiles `load i64, i64 addrspace(256)* %p` **without error** but emits a
**plain `ldr x0, [x0]`** — the per-CPU semantics are **silently dropped** (no
`TPIDR_EL1` base). This is a **silent miscompile**, the single most important
correctness item of the retarget, and it lives in `ssa_llvm.ad`
(`ll_put_ity_ptr` / `sv_as256`, gated behind `cg_target_kernel`). AArch64 has no
GS-style address space; the retarget must emit an explicit per-CPU base read
(`mrs xN, TPIDR_EL1`) + offset, or an `llvm.read_register` intrinsic. Bounded
and localized (one emitter path), but must be done before any SMP/per-CPU kernel
code is trusted.

### 2c. Target strings, code model, VA layout, linker/boot

| item | finding | class |
|------|---------|-------|
| `target triple` | 1 line, hardcoded `x86_64-pc-linux-gnu` (`ssa_llvm.ad:1546`) | (b) one-line, per-target |
| `target datalayout` | **none emitted** — clang infers from `--target`. x86_64 and aarch64 are both LP64 little-endian, so no datalayout conflict | (a) as-is |
| `-mcmodel=kernel` | **AArch64 has no `kernel` code model.** The x86 kernel lane passes `-mcmodel=kernel` (negative-2GB, for the `0xffffffff8...` higher-half). AArch64 uses `-mcmodel=small`(±4 GB, PIE-friendly) or `-mcmodel=large`; a high kernel VA is achieved via the **linker script + MMU TTBR1** (upper VA half `0xffff_...`), NOT a code model. `build_kernel_llvm.sh` clang flags need an arch branch. | (c) bringup |
| higher-half VA `0xffffffff80000000` | x86 PML4-511 convention. AArch64 kernels live in the **TTBR1 upper half** (e.g. `0xffff_0000_0000_0000+`). No `inttoptr` in the IR bakes this constant — it comes from `kernel.lds` + boot MMU setup — so the IR is unaffected; the constant moves to the new linker script + page-table bringup. | (c) bringup |
| `arch/x86/kernel/kernel.lds` | `OUTPUT_ARCH(i386:x86-64)`, `ENTRY(_start)`, `KERNEL_VBASE=0xffffffff80000000`, AP-trampoline @0x8000, multiboot low stub | (c) full rewrite → `arch/arm64/.../kernel.lds` |
| boot/entry `.S` stubs | **22 files under `arch/x86/` + 4 under `fs/`,`drivers/`** (`header.S` multiboot, `head_64.S` long-mode+bss-zero, IDT/GDT/TSS, syscall entry, IRQ/trap entry, FPU, KPTI, SMP/AP trampoline, spinlock, sched switch, sigret, vDSO, string) | (c) native rewrite → `arch/arm64/` (EL1 entry, exception-vector table `VBAR_EL1`, MMU/TTBR bringup, GIC, PSCI) |

### Category rollup

- **(a) target-independent, works as-is:** the entire structured IR body
  (11,059 functions), all globals, no datalayout conflict. This is the bulk of
  the 33 MB and it compiled for aarch64 with zero IR errors.
- **(b) needs an AArch64 asm/intrinsic equivalent (in `ssa_llvm.ad`):** triple
  string (1 line), the 52 inline-asm sites (30 trivial + 14 mechanical + 8 real),
  and the 236 `%gs`-percpu accesses (one emitter path). This is the **compiler
  retarget** and it is small and localized.
- **(c) native `.S`/linker/boot-shim rewrite (bringup layer):** 22+ `.S` stubs,
  `kernel.lds`, code-model/VA story, MMU + exception vectors + GIC + PSCI. This
  is the **new `arch/arm64/` tree** — the genuine engineering, mirroring what
  `arch/x86/` already provides.

---

## 3. Phased bringup plan (mirrors the x86 kernel-LLVM lane staging)

The x86 LLVM kernel went user-apps → freestanding `.ll` compiles → link with
`.S` stubs → boot → shell (Phases 5b–5s). ARM64 follows the same ladder, and
Phase A1 is **already green** (§1).

### Phase A1 — user-mode Adder apps on ARM64 (DONE in this spike)
- **Deliverable:** `scripts/arm64_llvm_poc.sh` — Adder→`.ll`→`clang --target=aarch64`→`qemu-aarch64`.
- **Acceptance gate (MET):** `whole_prog` output byte-identical to x86_64 (`16834`, matching sha256).
- **Next within A1:** teach `ssa_llvm.ad` a `--target=aarch64-*` flag that emits
  (a) the aarch64 triple and (b) `svc #0`/`x8`/`x0..x5` for `__syscallN` with an
  aarch64 Linux syscall-number table (write=64, exit=93, …). Gate additively;
  x86 output must stay byte-identical (`scripts/test_native_vs_seed_kobjdiff.sh`,
  0 divergences — the native path is not on the LLVM emitter, but run it anyway
  after any ssa file edit). Gate: `objdiff` corpus of `user/*.ad` runs identically
  under qemu-aarch64 and native.
- **Risk:** low. Proven. Syscall-number table is bookkeeping.

### Phase A2 — freestanding kernel `.ll` compiles clean for aarch64 (the compiler retarget)
- **Work:** in `ssa_llvm.ad`, behind the aarch64 target flag: (1) emit aarch64
  equivalents for the 5 trivial barrier mnemonics + the 14 trampoline stubs;
  (2) replace `addrspace(256)` percpu with a `TPIDR_EL1`-based emission (the 236
  sites); (3) provide aarch64 forms (or gated stubs) for cpuid/rdrand/mul128/
  s3/reset. Barriers/percpu are the priority; cpuid/rng/suspend can emit a
  `brk`/stub trap first and be filled in.
- **Acceptance gate:** `clang --target=aarch64-none-elf -c kernel_main.ll` → `0`
  errors (today: 186, all inline-asm) AND a per-CPU load disassembles to a
  `mrs …TPIDR_EL1` + offset, NOT a bare `ldr`. Plus x86 byte-identical
  (kobjdiff 0).
- **Risk:** medium. The percpu retarget is the correctness crux (silent
  miscompile if wrong). Well-contained to one emitter path.

### Phase A3 — boot stubs + MMU + exception vectors on `qemu-system-aarch64 -M virt` → shell
- **Work:** new `arch/arm64/` — EL2→EL1 drop + `_start`, `VBAR_EL1` exception
  vector table, MMU/TTBR0+TTBR1 page-table bringup (upper-half kernel VA),
  `kernel.lds` (`OUTPUT_ARCH(aarch64)`, aarch64 VBASE), GIC + timer + PSCI +
  PL011 UART console; arch branch in `build_kernel_llvm.sh` (drop
  `-mcmodel=kernel`, use `-mcmodel=small`/`large`; aarch64 `as`/`ld`). Use the
  present `qemu-efi-aarch64` (AAVMF) or direct `-kernel`.
- **Acceptance gate (staged, mirroring x86 5b→5s):** (i) links a bootable ELF;
  (ii) reaches early `printk`/UART on `qemu-system-aarch64 -M virt`; (iii)
  demand-paging + scheduler up; (iv) `rfork` child dispatched; (v) shell prompt.
- **Risk:** high-effort but low-uncertainty — this is a **standard AArch64
  bringup**, and `arch/x86/` is a complete reference for every stub. `-M virt`
  is fully virtio (no vendor drivers), so it maps onto the existing native-HW
  invariant (virtio/AHCI/xHCI native).

### Biggest risks, ranked
1. **`%gs`→`TPIDR_EL1` percpu retarget (236 sites)** — silent miscompile if the
   emission is wrong; no compiler error to catch it. Gate with a disassembly
   assertion, not just "it compiled."
2. **Boot/MMU/exception-vector bringup (Phase A3)** — the real labor; low
   conceptual risk (well-trodden, `-M virt` is clean) but the largest LOC.
3. **cpuid/rdrand/S3/reset** — different mechanisms on aarch64; stub-able for a
   first boot, real work later.
4. **Syscall-number ABI (user-mode only)** — Adder `__syscallN` uses x86 Linux
   numbers; needs an aarch64 table. Irrelevant to the freestanding kernel.

**Bottom line for the user:** ARM64 is a **near-term retarget for user-mode
today** and a **bounded, well-understood bringup for the kernel** — not a
rewrite. The north-star bet holds: because the backend emits target-independent
LLVM IR, the structured-IR body (11k functions) is free; the entire cost is the
small `ssa_llvm.ad` asm/percpu delta (Phase A2) plus a fresh `arch/arm64/` boot
layer (Phase A3) that mirrors the existing `arch/x86/` one-for-one.

---

## Appendix — artifacts & reproduction
- PoC script: `scripts/arm64_llvm_poc.sh` (run: `bash scripts/arm64_llvm_poc.sh`).
- Emitted IR inspected: `build/arm64poc/{whole_prog.ll, kernel_main.ll}` (gitignored build dir).
- aarch64 clang error log: `build/arm64poc/aarch64_clang_err.txt` (186 errors, all inline-asm).
- No compiler source (`ssa_llvm.ad`/`ssa.ad`/`codegen.ad`) modified in this spike
  → the default x86 native path is byte-identical by construction (no
  `kobjdiff` divergence possible; nothing on the native codegen path changed).
