"""Stack-slot -> register promotion pass for the x86_64 backend (Track 6, -O2).

The single-pass backend in ``codegen_x86.py`` is a *stack machine*: every
local variable lives in an ``OFF(%rbp)`` stack slot, and EVERY read or write
of that local round-trips through memory (``movq OFF(%rbp), %rax`` /
``movq %rax, OFF(%rbp)``). In a tight loop the loop counter and accumulators
get reloaded and re-stored on every single iteration, which is the dominant
cost of the un-optimised code (see ``docs/bench_adder_host.md``).

This pass is a small **register allocator over the stack slots**: it promotes
the hottest address-never-taken full-width scalar slots of each function into
the callee-saved registers ``%rbx, %r12, %r13, %r14, %r15`` — registers the
backend NEVER emits (verified: zero occurrences in any generated function) and
the ``-O1`` peephole NEVER touches (it scratches only ``%r8..%r11``). The slot
then lives purely in a register; its memory traffic disappears.

It runs AFTER the ``-O1`` peephole (so the peephole's push/pop->scratch
forwarding has already collapsed the operand round-trips), as the second stage
of the ``-O2`` pipeline.

### Why this is correct (the safety contract)

A slot is promoted ONLY when, across the whole function body, EVERY textual
appearance of ``OFF(%rbp)`` for that offset is one of exactly two forms:

    movq OFF(%rbp), %reg      (a full-width 8-byte load)
    movq %reg,      OFF(%rbp) (a full-width 8-byte store)

If the offset EVER appears in any other shape — a sized ``movb/movl/...``, a
``movzbq``/``movsbq`` (sign/zero-extending sized load), an ``lea``
(address-of), an indexed base ``OFF(%rbp,...)``, or as an operand of any non
``movq`` instruction — the slot is rejected and left entirely in memory. This
guarantees the slot is a pure 8-byte scalar whose address never escapes, so a
register holds exactly the same value the memory slot would. The canary slot
``-8(%rbp)`` is always excluded (it is read with ``xorq ...(%rip)`` against
memory in the epilogue and must stay in memory).

The promoted register is saved/restored through a FRESH save slot carved out
of an enlarged frame (the ``subq $N, %rsp`` is grown), with the save store in
the prologue and the restore before every ``leave`` (the function's exits).
This avoids any interaction with ``leave`` resetting ``%rsp`` that a raw
``push``/``pop`` of the callee-saved register would have.

Correctness is enforced by ``scripts/fuzz_adder.sh`` with ``FUZZ_OPT=2``
(predicted-output oracle, tens of thousands of random programs) and the
cross-language agreement check in ``scripts/bench_adder_host.sh``.

Entry point: ``optimize(lines: list[str]) -> list[str]``.
"""

from __future__ import annotations

import re

# Callee-saved registers the backend never uses and the -O1 peephole never
# touches. Order = promotion priority (arbitrary, all equally free).
_ALLOC_POOL = ["%rbx", "%r12", "%r13", "%r14", "%r15"]

# A function is bounded by its `.type <name>, @function` directive (the entry
# label `<name>:` follows it) through its closing `.size <name>, .-<name>`.
_TYPE_FUNC_RE = re.compile(r"^\s*\.type\s+([A-Za-z_.$][\w.$]*),\s*@function\s*$")
_SIZE_RE = re.compile(r"^\s*\.size\s+([A-Za-z_.$][\w.$]*),")
_LABEL_RE = re.compile(r"^([A-Za-z_.$][\w.$]*):\s*$")

# An rbp-relative slot reference: OFF(%rbp) with OFF a signed decimal.
_SLOT_RE = re.compile(r"(-?\d+)\(%rbp\)")

# A simple full-width load:  movq OFF(%rbp), %reg
_LOAD_RE = re.compile(r"^\s*movq\s+(-?\d+)\(%rbp\),\s*(%[a-z0-9]+)\s*$")
# A simple full-width store: movq %reg, OFF(%rbp)
_STORE_RE = re.compile(r"^\s*movq\s+(%[a-z0-9]+),\s*(-?\d+)\(%rbp\)\s*$")

# Prologue frame reservation: `subq $N, %rsp`
_SUBQ_RE = re.compile(r"^\s*subq\s+\$(\d+),\s*%rsp\s*$")


def _split_functions(lines):
    """Yield (entry, end, name) for each function body.

    `entry` is the `<name>:` entry-label index, `end` is exclusive (the line
    after the `.size <name>, .-<name>` directive). Code outside any function
    (data, rodata) is skipped.
    """
    i = 0
    n = len(lines)
    while i < n:
        m = _TYPE_FUNC_RE.match(lines[i])
        if not m:
            i += 1
            continue
        name = m.group(1)
        # Entry label `<name>:` at or after this directive.
        j = i + 1
        entry = None
        while j < n:
            lm = _LABEL_RE.match(lines[j])
            if lm and lm.group(1) == name:
                entry = j
                break
            if _TYPE_FUNC_RE.match(lines[j]):
                break
            j += 1
        if entry is None:
            i += 1
            continue
        # Closing `.size <name>,` directive.
        k = entry + 1
        end = None
        while k < n:
            sm = _SIZE_RE.match(lines[k])
            if sm and sm.group(1) == name:
                end = k + 1
                break
            k += 1
        if end is None:
            end = n
        yield (entry, end, name)
        i = end


def _collect_slots(body):
    """Return {offset: usage_info} for every OFF(%rbp) offset in `body`.

    usage_info: {'load': int, 'store': int, 'ok': bool}. 'ok' is True only
    when every appearance of that offset is a simple full-width load/store.
    """
    info = {}

    def touch(off):
        return info.setdefault(off, {"load": 0, "store": 0, "ok": True})

    for line in body:
        stripped = line.strip()
        if not stripped or stripped.startswith((".", "#")) or \
                _LABEL_RE.match(line):
            continue
        offs = _SLOT_RE.findall(line)
        if not offs:
            continue
        lm = _LOAD_RE.match(line)
        sm = _STORE_RE.match(line)
        if lm:
            touch(int(lm.group(1)))["load"] += 1
            continue
        if sm:
            touch(int(sm.group(2)))["store"] += 1
            continue
        # Any other shape referencing a slot => reject every offset it names.
        for off in offs:
            touch(int(off))["ok"] = False
    return info


def _has_indexed_rbp(body):
    """True if any line uses an indexed %rbp base `(%rbp,` (array on stack).
    Defensive: the backend doesn't emit this for promotable scalars, but if
    it appears we refuse to promote anything in the function."""
    for line in body:
        if "(%rbp," in line:
            return True
    return False


def _optimize_function(lines, start, end, name):
    """Promote slots within lines[start:end]; return (new_lines, changed)."""
    body = lines[start:end]

    sub_idx = None
    frame = 0
    for idx, line in enumerate(body):
        sm = _SUBQ_RE.match(line)
        if sm:
            sub_idx = idx
            frame = int(sm.group(1))
            break

    slots = _collect_slots(body)
    if not slots:
        return lines, False

    if _has_indexed_rbp(body):
        return lines, False

    candidates = []
    for off, rec in slots.items():
        if not rec["ok"]:
            continue
        if off == -8:                      # canary slot — must stay in memory
            continue
        uses = rec["load"] + rec["store"]
        if uses == 0:
            continue
        candidates.append((uses, off))

    if not candidates:
        return lines, False

    # Hottest first; tie-break on offset for deterministic output.
    candidates.sort(key=lambda c: (-c[0], c[1]))
    chosen = candidates[: len(_ALLOC_POOL)]
    off_to_reg = {off: _ALLOC_POOL[i] for i, (_, off) in enumerate(chosen)}

    nsaved = len(off_to_reg)
    save_bytes = nsaved * 8
    new_frame = (frame + save_bytes + 15) & ~15   # keep 16-byte alignment
    # Save slots sit at the bottom of the enlarged frame, clear of the
    # existing locals which occupy [-frame, -1]. new_frame >= frame +
    # save_bytes by construction, so [-new_frame, -new_frame+save_bytes) is
    # disjoint from [-frame, -1].
    base = -new_frame
    save_off = {off: base + i * 8 for i, off in enumerate(off_to_reg)}

    new_body = list(body)

    # 1) Patch / insert the frame reservation.
    if sub_idx is not None:
        new_body[sub_idx] = f"    subq ${new_frame}, %rsp"
        prologue_end = sub_idx + 1
    else:
        ins = None
        for idx, line in enumerate(new_body):
            if line.strip() == "movq %rsp, %rbp":
                ins = idx + 1
                break
        if ins is None:
            return lines, False          # unexpected shape; bail out safely
        new_body.insert(ins, f"    subq ${new_frame}, %rsp")
        prologue_end = ins + 1

    # 2) Insert register-save stores at prologue_end.
    save_stores = [f"    movq {reg}, {save_off[off]}(%rbp)"
                   for off, reg in off_to_reg.items()]
    new_body[prologue_end:prologue_end] = save_stores

    # 3) Rewrite slot loads/stores -> register moves; restore before `leave`.
    restores = [f"    movq {save_off[off]}(%rbp), {reg}"
                for off, reg in off_to_reg.items()]
    final = []
    for line in new_body:
        lm = _LOAD_RE.match(line)
        if lm and int(lm.group(1)) in off_to_reg:
            dst = lm.group(2)
            reg = off_to_reg[int(lm.group(1))]
            if dst != reg:
                final.append(f"    movq {reg}, {dst}")
            continue
        sm = _STORE_RE.match(line)
        if sm and int(sm.group(2)) in off_to_reg:
            src = sm.group(1)
            reg = off_to_reg[int(sm.group(2))]
            if src != reg:
                final.append(f"    movq {src}, {reg}")
            continue
        if line.strip() == "leave":
            final.extend(restores)
            final.append(line)
            continue
        final.append(line)

    return lines[:start] + final + lines[end:], True


def optimize(lines):
    """Promote stack slots to callee-saved registers, function by function.

    Processes functions back-to-front so earlier index ranges stay valid as
    later ranges are rewritten (length may change). Returns a new list."""
    funcs = list(_split_functions(lines))
    cur = list(lines)
    for (start, end, name) in reversed(funcs):
        cur, _ = _optimize_function(cur, start, end, name)
    return cur


def optimize_text(asm: str) -> str:
    """Convenience wrapper: promote slots over a full assembly string."""
    trailing_nl = asm.endswith("\n")
    lines = asm.split("\n")
    if trailing_nl and lines and lines[-1] == "":
        lines = lines[:-1]
    out = optimize(lines)
    return "\n".join(out) + ("\n" if trailing_nl else "")
