"""Peephole optimizer for the single-pass x86_64 backend (Track 6, -O1).

The backend in ``codegen_x86.py`` is a single-pass AST->asm emitter that
implements a *stack machine*: every binary operator evaluates one operand
into ``%rax``, ``pushq``-es it, evaluates the other operand into ``%rax``,
``popq``-s the first into ``%rcx``, and applies the op. It also materialises
constants via ``movq $imm, %rax`` even when the value is about to be pushed,
and lowers a boolean condition to ``setCC %al; movzbq %al, %rax; testq
%rax, %rax; jz/jnz`` even when the boolean immediately feeds a branch.

This module rewrites the emitted *assembly text* with a set of strictly
LOCAL, provably-safe transforms, run to a fixpoint:

  P_branch  setCC %al ; movzbq %al, %rax ; testq %rax, %rax ; jz/jnz L
            -> a single jCC to L (sense adjusted). Eliminates the boolean
            materialisation when it only feeds a branch.
  P_reload  movq %rax, X ; movq X, %rax -> drop the reload (%rax already
            holds X's value; the store is kept since X may be read later).
  P_imm     movq $imm, %rax ; pushq %rax -> pushq $imm (imm fits in signed
            32 bits; pushq sign-extends to 64, matching the movq+push).
  P_pushpop push/pop forwarding: a `pushq %REG` whose matching `popq %DST`
            (same linear region, balanced stack depth) has NO call / label /
            branch between them is converted to a move through a fresh
            caller-saved scratch register (%r8..%r11, by nesting depth). The
            existing codegen never touches %r8..%r11, and with no intervening
            call they are preserved, so this removes the memory round-trip
            while preserving semantics.

Every transform is conservative: anything it cannot prove safe, it leaves
alone. Correctness is enforced by ``scripts/fuzz_adder.sh`` (predicted-output
oracle over tens of thousands of random programs) and the cross-language
agreement check in ``scripts/bench_adder_host.sh``.

Entry point: ``optimize(lines: list[str]) -> list[str]``.
"""

from __future__ import annotations

import re

# Registers the single-pass backend NEVER uses for its stack machine. These
# are caller-saved (clobbered by `call`), so they are only safe as a push/pop
# scratch across a region with NO intervening call -- which P_pushpop
# guarantees by construction.
_SCRATCH_POOL = ["%r8", "%r9", "%r10", "%r11"]

# An instruction line: leading whitespace + mnemonic + operands. Labels,
# directives (`.foo`), and comments are NOT instructions for our purposes.
_INSN_RE = re.compile(r"^\s+([a-z][a-z0-9]*)\b(.*)$")


def _parse(line: str):
    """Return (mnemonic, operand_str) for an instruction line, else None."""
    m = _INSN_RE.match(line)
    if not m:
        return None
    return m.group(1), m.group(2).strip()


def _is_label_def(line: str) -> bool:
    # A label definition ends in ':' and is not an instruction. Covers both
    # `.while_x_1:` and `main:`.
    return line.strip().endswith(":")


def _is_directive(line: str) -> bool:
    s = line.strip()
    return s.startswith(".") and not s.endswith(":")


# Map setCC suffix -> the jCC that branches when the condition is TRUE, and
# its negation (branch when FALSE).
_SETCC_TRUE_J = {
    "sete": "je", "setne": "jne",
    "setl": "jl", "setle": "jle", "setg": "jg", "setge": "jge",
    "setb": "jb", "setbe": "jbe", "seta": "ja", "setae": "jae",
}
_SETCC_FALSE_J = {
    "sete": "jne", "setne": "je",
    "setl": "jge", "setle": "jg", "setg": "jle", "setge": "jl",
    "setb": "jae", "setbe": "ja", "seta": "jbe", "setae": "jb",
}


# ----------------------------------------------------------------------------
# P_pushpop: push/pop forwarding through a scratch register
# ----------------------------------------------------------------------------

def _region_bounds(lines, start):
    """Return the half-open [start, end) of the maximal LINEAR region that
    begins at `start`, i.e. up to (but excluding) the next label/directive/
    branch/call/ret/leave/jmp/syscall — any instruction that breaks straight-
    line flow. The region is where a caller-saved scratch register keeps its
    value, so push/pop forwarding within it is safe."""
    n = len(lines)
    end = start
    while end < n:
        line = lines[end]
        if _is_label_def(line) or _is_directive(line):
            break
        pj = _parse(line)
        if pj is not None:
            mn = pj[0]
            if mn in ("call", "syscall", "ret", "leave", "jmp") \
                    or mn.startswith("j"):
                # The boundary instruction itself is included so its operands
                # (e.g. `jz L`) are scanned for register liveness, but stack
                # ops never cross it.
                end += 1
                break
        end += 1
    return start, end


def _regs_in(lines, lo, hi):
    """Set of x86 registers (any width, normalised to a coarse family token)
    mentioned anywhere in lines[lo:hi]. Used to pick a scratch register that
    is provably unused across a region."""
    txt = "\n".join(lines[lo:hi])
    return set(re.findall(r"%[a-z][a-z0-9]*", txt))


# Sub-register aliases so a scratch %r8 isn't chosen when %r8d/%r8b is live.
_SCRATCH_ALIASES = {
    "%r8": ("%r8", "%r8d", "%r8w", "%r8b"),
    "%r9": ("%r9", "%r9d", "%r9w", "%r9b"),
    "%r10": ("%r10", "%r10d", "%r10w", "%r10b"),
    "%r11": ("%r11", "%r11d", "%r11w", "%r11b"),
}


def _pass_pushpop_forward(lines):
    """Convert balanced push/pop pairs with no intervening branch/call into
    scratch-register moves. Each `pushq %REG`/`pushq $imm` is matched to its
    balanced `popq %DST`:

      pushq SRC   ->   movq SRC, %scratch
      popq  DST   ->   movq %scratch, DST

    Safety:
      * Pair (i -> j) must lie within one LINEAR region (no label/branch/call
        between them) so a caller-saved scratch survives — `_region_bounds`.
      * The chosen scratch register must be UNUSED anywhere in the whole
        enclosing region (not just [i, j]). This is what makes the pass robust
        under iteration: a scratch assigned to an OUTER pair in a previous
        round is already written into the region text, so a later inner pair
        sees it as live and avoids it. (The earlier nesting-level heuristic
        could collide a live scratch — the mmul miscompile.)
      * Sub-register aliases are respected (%r8 vs %r8d/%r8b).
    """
    n = len(lines)
    rewrite = {}

    # Walk region by region so scratch liveness is scoped correctly.
    pos = 0
    while pos < n:
        line = lines[pos]
        if _is_label_def(line) or _is_directive(line) or _parse(line) is None:
            pos += 1
            continue
        rlo, rhi = _region_bounds(lines, pos)
        # Within this region, match balanced push/pop pairs.
        i = rlo
        while i < rhi:
            p = _parse(lines[i])
            if not (p and p[0] == "pushq"):
                i += 1
                continue
            src = p[1]
            is_imm = bool(re.fullmatch(r"\$-?\d+", src))
            if not (re.fullmatch(r"%[a-z0-9]+", src) or is_imm):
                i += 1
                continue
            # Find matching pop by depth, confined to this region.
            depth = 1
            j = i + 1
            while j < rhi and depth > 0:
                pj = _parse(lines[j])
                if pj is None:
                    j += 1
                    continue
                if pj[0] == "pushq":
                    depth += 1
                elif pj[0] == "popq":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            if depth != 0 or j >= rhi:
                i += 1
                continue
            pj = _parse(lines[j])
            dst = pj[1]
            if not re.fullmatch(r"%[a-z0-9]+", dst):
                i += 1
                continue
            # Pick a scratch register not referenced anywhere in the region
            # (including registers introduced by prior rewrites this run).
            live = _regs_in(lines, rlo, rhi)
            scratch = None
            for cand in _SCRATCH_POOL:
                if not any(a in live for a in _SCRATCH_ALIASES[cand]):
                    scratch = cand
                    break
            if scratch is None:
                i += 1
                continue
            indent_i = lines[i][:len(lines[i]) - len(lines[i].lstrip())]
            indent_j = lines[j][:len(lines[j]) - len(lines[j].lstrip())]
            new_i = f"{indent_i}movq {src}, {scratch}"
            new_j = f"{indent_j}movq {scratch}, {dst}"
            lines[i] = new_i
            lines[j] = new_j
            rewrite[i] = new_i
            rewrite[j] = new_j
            i += 1
        pos = rhi

    return lines, bool(rewrite)


# ----------------------------------------------------------------------------
# P_imm: immediate push  (movq $imm, %rax ; pushq %rax -> pushq $imm)
# ----------------------------------------------------------------------------

def _pass_imm_push(lines):
    out = []
    changed = False
    i = 0
    n = len(lines)
    while i < n:
        p = _parse(lines[i])
        if p and p[0] == "movq" and i + 1 < n:
            m = re.fullmatch(r"\$(-?\w+),\s*%rax", p[1])
            p2 = _parse(lines[i + 1])
            if m and p2 and p2[0] == "pushq" and p2[1] == "%rax":
                imm = m.group(1)
                if re.fullmatch(r"-?\d+", imm):
                    val = int(imm)
                    if -(2**31) <= val < 2**31:
                        indent = lines[i + 1][:len(lines[i + 1])
                                              - len(lines[i + 1].lstrip())]
                        out.append(f"{indent}pushq ${imm}")
                        changed = True
                        i += 2
                        continue
        out.append(lines[i])
        i += 1
    return out, changed


# ----------------------------------------------------------------------------
# P_reload: dead store-reload  (movq %rax, X ; movq X, %rax -> drop reload)
# ----------------------------------------------------------------------------

def _pass_store_reload(lines):
    out = []
    changed = False
    i = 0
    n = len(lines)
    while i < n:
        p = _parse(lines[i])
        if p and p[0] == "movq" and i + 1 < n:
            m = re.fullmatch(r"%rax,\s*(.+)", p[1])
            p2 = _parse(lines[i + 1])
            if m and p2 and p2[0] == "movq":
                dst = m.group(1).strip()
                m2 = re.fullmatch(r"(.+),\s*%rax", p2[1])
                if m2 and m2.group(1).strip() == dst:
                    # store wrote %rax->dst; reload reads dst->%rax, but %rax
                    # already holds it. Keep the store (dst may be read
                    # later), drop the redundant reload.
                    out.append(lines[i])
                    changed = True
                    i += 2
                    continue
        out.append(lines[i])
        i += 1
    return out, changed


# ----------------------------------------------------------------------------
# P_branch: condition->branch fusion
# ----------------------------------------------------------------------------

def _pass_branch_fusion(lines):
    """setCC %al ; movzbq %al, %rax ; testq %rax, %rax ; jz/jnz L
       -> a single jCC to L (sense adjusted)."""
    out = []
    changed = False
    i = 0
    n = len(lines)
    while i < n:
        if i + 3 < n:
            p0 = _parse(lines[i])
            p1 = _parse(lines[i + 1])
            p2 = _parse(lines[i + 2])
            p3 = _parse(lines[i + 3])
            if (p0 and p0[0] in _SETCC_TRUE_J and p0[1] == "%al"
                    and p1 and p1[0] == "movzbq" and p1[1] == "%al, %rax"
                    and p2 and p2[0] == "testq" and p2[1] == "%rax, %rax"
                    and p3 and p3[0] in ("jz", "jnz")):
                setcc = p0[0]
                target = p3[1]
                # jz branches when boolean FALSE; jnz when TRUE.
                newj = (_SETCC_FALSE_J[setcc] if p3[0] == "jz"
                        else _SETCC_TRUE_J[setcc])
                indent = lines[i + 3][:len(lines[i + 3])
                                      - len(lines[i + 3].lstrip())]
                out.append(f"{indent}{newj} {target}")
                changed = True
                i += 4
                continue
        out.append(lines[i])
        i += 1
    return out, changed


# ----------------------------------------------------------------------------
# Driver
# ----------------------------------------------------------------------------

_PASSES = [
    _pass_branch_fusion,
    _pass_store_reload,
    _pass_imm_push,
    _pass_pushpop_forward,
]


def optimize(lines, max_rounds: int = 8):
    """Run the peephole passes to a fixpoint (bounded). `lines` is the list of
    assembly text lines (no trailing newlines). Returns a new list."""
    cur = list(lines)
    for _ in range(max_rounds):
        any_change = False
        for p in _PASSES:
            cur, ch = p(cur)
            any_change = any_change or ch
        if not any_change:
            break
    return cur


def optimize_text(asm: str) -> str:
    """Convenience wrapper: optimize a full assembly string."""
    trailing_nl = asm.endswith("\n")
    lines = asm.split("\n")
    if trailing_nl and lines and lines[-1] == "":
        lines = lines[:-1]
    out = optimize(lines)
    return "\n".join(out) + ("\n" if trailing_nl else "")
