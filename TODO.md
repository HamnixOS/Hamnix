# Hamnix TODO

Open work items not yet scheduled to a specific milestone. Items here
are fair game for any contributor — human or AI agent.

## Language

- **`do-while` loop** — Python lacks it, but it's the right shape for
  "execute body at least once, then test." A reasonable surface
  syntax:

  ```python
  do:
      body
  while condition
  ```

  Implementation touches `compiler/lexer.py` (add `do` keyword),
  `compiler/parser.py` (`parse_do_while`), `compiler/ast_nodes.py`
  (`DoWhile` node), and `compiler/codegen_x86.py` (lower to a
  `top: body; cmp; jne top` pair).
  See [Adder compiler quirks](memory/feedback_compiler_quirks.md)
  for known compiler footguns that may interact.

## Compiler

- Unsigned-comparison codegen extended past `<`/`<=`/`>`/`>=` — also
  need `shrq` (logical) for unsigned right-shift (today always signed
  `sarq`), and `divq`/`modq` family for unsigned types (today always
  signed `idivq`).
- First-class function pointers — currently every indirect call
  drops into `asm_volatile("call *%rax")`. A real `Fn[R, *A]` type
  with proper SysV codegen would clean up dozens of asm helpers.
- `match`/`case` keyword tokenisation — reserved but not implemented;
  pick one of "Python 3.10 match" or "C switch" and ship.

## Kernel / L-track

- `MAX_EXPORTS=512` ceiling — bump again when we cross ~450 used.
- nf_conntrack core (~155 UND) — blocking conntrack helpers.
- `8021q.ko` (~118 UND, VLAN).
- `libphy.ko` (~153 UND, Ethernet PHY).
- usbcore + xhci_hcd — real-hardware drivers.

## Userspace / U-track

- Real vDSO blob (mapped page advertised via `AT_SYSINFO_EHDR`),
  replacing the U11-era kernel-side `_lookup_dynsym` hack we
  retired in U20.
- `futex` (202) — real wait/wake table. Today returns -ENOSYS;
  glibc tolerates but multi-threaded musl will need it.
- `clone` / `clone3` (56 / 435) — pthread bring-up.
- Per-task heap state — `linux_brk` is a single global today;
  multi-process Linux binaries will collide.

## Toolchain & install

- Real-hardware boot (ThinkPad). FAT32 read + EXT4 r/w done;
  UEFI handover outstanding.
