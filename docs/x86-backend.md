# x86_64 Backend

Pynux is being used to incrementally rewrite Linux kernel code on x86_64, one
loadable kernel module at a time. This requires an x86_64 code generator
distinct from the ARM Thumb-2 backend used by the microcontroller OS.

## Decision: hand-written encoder, not LLVM

The x86_64 backend (`compiler/codegen_x86.py`) is a **hand-written encoder**
that emits GNU `as` assembly, mirroring the architecture of the existing
hand-written ARM backend (`compiler/codegen_arm.py`).

Routing through LLVM (llvmlite or textual IR) was considered and explicitly
rejected. LLVM would have provided the SysV AMD64 ABI, ELF relocatable output,
and kernel mitigation flags "for free", but at the cost of an external
dependency. The hand-written path keeps Pynux dependency-free and consistent
with the ARM backend, at the cost of implementing the ABI and the x86
mitigations by hand. That cost is accepted deliberately.

## Target

`pynux compile --target=x86_64-linux-kernel-module` emits a `.S` file. The
Linux kernel build system (`kbuild`) owns assembly, link, and `modpost`,
turning the `.S` into a loadable `.ko`. Pynux does not invoke `as`/`ld` itself
for this target, which avoids host-vs-kernel assembler-flag mismatch.

## Kernel codegen constraints

x86_64 kernel code must:

- Avoid the SysV 128-byte red zone (clobbered by IRQs/exceptions in kernel
  context). Pynux always frames with `%rbp` and uses no leaf-function stack
  tricks, so generated code is red-zone-safe by construction.
- Maintain 16-byte stack alignment at call boundaries.
- Emit `endbr64` on indirect call targets when the kernel has
  `CONFIG_X86_KERNEL_IBT`. `codegen_x86.py` emits `endbr64` at every function
  entry unconditionally (`EMIT_ENDBR`) — a 4-byte NOP when IBT is off.
- Use retpoline thunks for indirect calls under `CONFIG_MITIGATION_RETPOLINE`,
  and a return thunk under `CONFIG_MITIGATION_RETHUNK`. Not yet emitted.
- Emit kCFI prologues on indirect call targets under `CONFIG_CFI_CLANG`. Not
  yet emitted.

Initial development targets a custom-built kernel with these mitigations
**off** (see `scripts/x86_kernel_config.sh`). They are ratcheted on as the
codegen matures.
