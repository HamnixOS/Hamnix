#!/usr/bin/env python3
# tests/fuzz/adder_fuzzer.py
#
# A property-based fuzzer for the hand-rolled single-pass x86_64 Adder
# backend (adder/compiler/codegen_x86.py).
#
# WHY: The backend is a solo, hand-written single-pass encoder. A May-2026
# audit found FIVE silent miscompiles (signed/unsigned compare, sub-8-byte
# pointer writes, 2-D array addressing). Silent miscompiles are the worst
# bug class — green tests, wrong answers. This fuzzer measures and de-risks
# that surface, and is the regression net for the upcoming Track-6 optimizer.
#
# HOW (predicted-output oracle, no second compiler):
#   The generator builds a RANDOM VALID Adder program and, AS IT BUILDS,
#   computes the program's expected printed result in Python using the EXACT
#   same wrapping/signedness rules the target machine uses (two's complement
#   at the declared bit width). Every expression node carries both its Adder
#   source text and its concrete Python value. The program ends by printing
#   one 64-bit accumulator. We compile to the `x86_64-linux` target, RUN THE
#   ELF ON THE HOST (no QEMU), and compare actual stdout + exit code against
#   the value the generator already knew. A mismatch is a miscompile; a
#   compiler exception on this well-formed input is a compiler crash.
#
# This single mechanism covers the whole May bug class: integer arithmetic
# (incl. sign-extension / widening), signed AND unsigned comparisons,
# pointer/array stores of 1/2/4/8-byte width, 2-D array addressing, loops,
# conditionals, function calls/returns, locals, and globals.
#
# Usage:
#   python3 tests/fuzz/adder_fuzzer.py --count 20000 --seed 1
#   python3 tests/fuzz/adder_fuzzer.py --repro 12345     # rebuild one program
#   python3 tests/fuzz/adder_fuzzer.py --emit 12345      # print its source
#
# Determinism: each program is generated from a per-program seed derived from
# (--seed, program-index), so any failing program reproduces in isolation.

import argparse
import os
import random
import struct
import subprocess
import sys
from pathlib import Path

# --------------------------------------------------------------------------
# Paths. The compiler resolves user/linux-runtime.S relative to the Hamnix
# repo root (the parent of adder/compiler is exposed as `compiler` at root),
# so we must invoke `python3 -m compiler.adder` with CWD = repo root.
# --------------------------------------------------------------------------
HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent           # .../Hamnix (or the worktree root)
WORK = REPO_ROOT / "build" / "fuzz_adder"

# --------------------------------------------------------------------------
# Integer type model. Each scalar type the fuzzer uses has a bit width and a
# signedness; the oracle wraps every intermediate value to this exact model,
# matching what the compiled machine code does (fixed-width two's complement).
# --------------------------------------------------------------------------
class IntType:
    def __init__(self, name, bits, signed):
        self.name = name
        self.bits = bits
        self.signed = signed
        self.mask = (1 << bits) - 1

    def wrap(self, v):
        """Reduce an arbitrary Python int to this type's representable value
        (two's complement at `bits` width), matching the machine."""
        v &= self.mask
        if self.signed and (v >> (self.bits - 1)) & 1:
            v -= (1 << self.bits)
        return v

    def __repr__(self):
        return self.name


I8  = IntType("int8",   8,  True)
U8  = IntType("uint8",  8,  False)
I16 = IntType("int16",  16, True)
U16 = IntType("uint16", 16, False)
I32 = IntType("int32",  32, True)
U32 = IntType("uint32", 32, False)
I64 = IntType("int64",  64, True)
U64 = IntType("uint64", 64, False)

ALL_TYPES   = [I8, U8, I16, U16, I32, U32, I64, U64]
STORE_TYPES = [I8, U8, I16, U16, I32, U32, I64, U64]   # array element widths


# --------------------------------------------------------------------------
# Floating-point type model. Floats are folded into the SAME uint64 g_accum
# oracle BIT-EXACTLY: every float VALUE the fuzzer materializes is derived
# from an INTEGER (via cast[floatN](int)), every float result is consumed by
# truncating back to int (cast[int64](float_expr)) — so the oracle predicts
# the exact integer the compiled code reaches, with NO precision/NaN guessing.
# `round` snaps a Python double to the type's representable value, matching
# the SSE op's hardware rounding (round-to-nearest-even, the SSE default):
#   float64 -> already a Python double (no-op)
#   float32 -> pack/unpack through IEEE single
# --------------------------------------------------------------------------
class FloatType:
    def __init__(self, name, bits):
        self.name = name
        self.bits = bits      # 32 or 64

    def round(self, x):
        """Snap double `x` to this type's representable value (SSE RNE)."""
        if self.bits == 32:
            return struct.unpack("<f", struct.pack("<f", x))[0]
        return x  # Python float IS an IEEE double

    def __repr__(self):
        return self.name


F32 = FloatType("float32", 32)
F64 = FloatType("float64", 64)
FLOAT_TYPES = [F32, F64]


def umask(bits):
    return (1 << bits) - 1


def _is_unsigned(t):
    return not t.signed


# --------------------------------------------------------------------------
# A typed value: the Adder source text + the EXACT 64-bit register content
# (`reg`, the raw bits in %rax, 0..2^64-1) + the static type (for signedness
# of compares/div/shift). This pairing is the by-construction oracle.
#
# CRITICAL MODELLING FACT (verified against the backend): Adder computes ALL
# arithmetic in 64-bit registers and does NOT truncate intermediates to their
# expression type. Truncation/extension happens ONLY at an explicit `cast[T]`
# and at a sized store. So the oracle must carry the full 64-bit register
# value through binops and only narrow at cast/store boundaries — mirroring
# %rax exactly. (An earlier version wrongly wrapped each node to its type and
# produced a flood of false "miscompiles".)
# --------------------------------------------------------------------------
U64MASK = (1 << 64) - 1


def _to_reg(v):
    """Raw 64-bit register content for a Python int (two's complement)."""
    return v & U64MASK


def _signed64(reg):
    """Interpret a 64-bit register's bits as a signed value."""
    return reg - (1 << 64) if reg >> 63 else reg


class TV:
    # `gt` = what the compiler's get_expr_type() returns for this node: an
    # IntType when it is statically known (a cast, a typed identifier), or
    # None when the compiler can't see it. CRITICAL: get_expr_type has NO case
    # for a BinaryExpr, so EVERY arithmetic/bitwise/division sub-expression
    # reports None to the signedness logic. The oracle must use `gt` (not the
    # node's modelled `typ`) when deciding compare/div signedness, because
    # that is exactly what _rel_cc / _binop_signed_op consult.
    __slots__ = ("src", "reg", "typ", "gt")

    def __init__(self, src, reg, typ, gt=None):
        self.src = src
        self.reg = reg & U64MASK   # the exact bits %rax would hold
        self.typ = typ             # the value's modelled type (for width/val)
        self.gt = gt               # get_expr_type() view: IntType or None

    @property
    def val(self):
        """The value as interpreted at this TV's static type (signed/unsigned,
        width-truncated) — used when the value is consumed at its declared
        type (e.g. stored into a variable of that type)."""
        return self.typ.wrap(self.reg)


def lit(value, typ):
    """A typed integer literal. Emit it through cast[T](...) so the literal's
    static type is unambiguous to the single-pass type inferencer. The
    register content is the value sign/zero-extended from `typ` to 64 bits.
    Because it is emitted as a cast, get_expr_type sees the cast's type."""
    v = typ.wrap(value)            # representable value at typ
    reg = _to_reg(v)               # sign/zero-extended into the 64-bit reg
    if v < 0:
        src = f"cast[{typ.name}](0 - {(-v)})"
    else:
        src = f"cast[{typ.name}]({v})"
    return TV(src, reg, typ, gt=typ)   # wrapped in cast -> gt = typ


def cast_to(tv, typ):
    """Model an Adder `cast[T](expr)`: truncate the source register to T's
    width, then re-extend into the 64-bit register using T's signedness
    (signed -> sign-extend, unsigned -> zero-extend). This is exactly what the
    backend's cast-widening fix-up does. get_expr_type of a CastExpr is T."""
    narrowed = typ.wrap(tv.reg)              # truncate to T width (signed view)
    reg = _to_reg(narrowed)                  # re-extend per T's signedness
    return TV(f"cast[{typ.name}]({tv.src})", reg, typ, gt=typ)


# --------------------------------------------------------------------------
# C usual-arithmetic-conversions, restricted to the integer types we use.
# The backend computes binary ops in 64-bit registers, but the *signedness*
# of compares/shifts/div is chosen from the operand static types (see
# codegen_x86 _rel_cc / _binop_signed_op: "either operand unsigned -> the
# whole op is unsigned"). The oracle must follow the same rule.
# --------------------------------------------------------------------------
def _gt_is_unsigned(gt):
    """Mirror codegen's _is_unsigned_type over a get_expr_type() result:
    True if unsigned, False if signed, None if unknown (gt is None)."""
    if gt is None:
        return None
    return not gt.signed


def cmp_is_unsigned(a, b):
    """Mirror codegen _rel_cc: a relational compare uses the UNSIGNED family
    if EITHER operand's get_expr_type() is unsigned; otherwise SIGNED (the
    default, including when both operands are unknown/None)."""
    return (_gt_is_unsigned(a.gt) is True) or (_gt_is_unsigned(b.gt) is True)


def divshift_is_signed(a, b):
    """Mirror codegen _binop_signed_op for / % >>: SIGNED iff some operand is
    known-signed AND none is known-unsigned; UNSIGNED otherwise (the default,
    including when both operands are unknown/None)."""
    au = _gt_is_unsigned(a.gt)
    bu = _gt_is_unsigned(b.gt)
    if au is True or bu is True:
        return False
    return au is False or bu is False


# --------------------------------------------------------------------------
# Expression generator. Builds a random arithmetic/comparison expression of a
# requested result type, tracking the concrete value.
# --------------------------------------------------------------------------
class Gen:
    def __init__(self, rng, env):
        self.rng = rng
        self.env = env          # list[TV]: in-scope int variables (src=ident)

    # ---- arithmetic / bitwise binary ops. The backend computes these in
    #      64-bit registers (addq/subq/imulq/andq/orq/xorq on %rax,%rcx) and
    #      leaves a 64-bit result — NO truncation to the node type. We model
    #      the exact 64-bit register result. The node's static `typ` only
    #      governs downstream signedness; it is NOT applied here.
    def _binop(self, depth, typ):
        a = self.expr(depth - 1)
        b = self.expr(depth - 1)
        op = self.rng.choice(["+", "-", "*", "&", "|", "^"])
        x, y = a.reg, b.reg
        if op == "+":
            r = x + y
        elif op == "-":
            r = x - y
        elif op == "*":
            # imulq is the low 64 bits of the product; signedness is
            # irrelevant to the low 64 bits, so raw-bit multiply is exact.
            r = x * y
        elif op == "&":
            r = x & y
        elif op == "|":
            r = x | y
        else:  # ^
            r = x ^ y
        src = f"({a.src} {op} {b.src})"
        # An arithmetic BinaryExpr has NO get_expr_type() case -> gt=None.
        return TV(src, _to_reg(r), typ, gt=None)

    # ---- division / modulo: 64-bit idivq/divq; signedness chosen by the
    #      compiler's _binop_signed_op over the operands' get_expr_type().
    def _divmod(self, depth, typ):
        a = self.expr(depth - 1)
        op = self.rng.choice(["/", "%"])
        # Divisor selection. Two forms exercise DIFFERENT backend paths:
        #   * BARE literal  `5` / `-7`  -> ND_INT_LIT / UNOP_NEG(ND_INT_LIT).
        #     get_expr_type is UNKNOWN (gt=None), so the op's signedness is
        #     governed solely by the dividend `a`. This is the form the native
        #     div/mod-by-constant STRENGTH REDUCTION pass recognizes (it reads
        #     nd_num directly), so we bias toward it to exercise the reduction.
        #   * cast[T](d)  -> ND_CAST: gt=T. Keeps the original mixed-signedness
        #     coverage (the cast form is NOT strength-reduced, so it also keeps
        #     the plain idiv/div path under test).
        # Constant variety: powers of two (incl. large), small odds, large
        # odds/primes, and +-1, on both small and 64-bit-significant values, so
        # the pow2-shift path, the unsigned magic path (incl. the "add" 65-bit
        # multiplier case), and the signed magic path all fire.
        pool = [
            1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 16, 17, 25, 32, 64, 100,
            128, 125, 256, 1000, 1023, 1024, 65535, 65536, 7919, 1000000007,
            (1 << 31), (1 << 32) + 1, (1 << 40) + 7, (1 << 62) + 3,
        ]
        d = self.rng.choice(pool)
        neg = self.rng.random() < 0.35
        bare = self.rng.random() < 0.75      # bias toward the SR-eligible form
        if bare:
            # Bare literal divisor; UNOP_NEG(lit) for negatives. gt=None.
            if neg:
                dsrc = f"(-{d})"
                dbits = _to_reg(-d)
            else:
                dsrc = f"{d}"
                dbits = _to_reg(d)
            b = TV(dsrc, dbits, typ, gt=None)
        else:
            # cast[T](d) divisor: get_expr_type = typ. This form is NOT strength-
            # reduced (it is an ND_CAST, not a bare literal); it keeps the plain
            # idiv/div path under test with a TYPED operand (mixed signedness).
            # The cast truncates to T's width at runtime, so the value MUST fit T
            # nonzero (a wrap-to-0 would divide by zero). Use a small divisor that
            # is safe for every T (including uint8/int8).
            small = self.rng.choice([2, 3, 4, 5, 6, 7, 8, 9, 10, 16, 25, 100])
            sval = -small if (neg and typ.signed) else small
            b = TV(f"cast[{typ.name}]({sval})", _to_reg(typ.wrap(sval)), typ, gt=typ)
        # Guard the one x86 idiv-trapping combo: a SIGNED INT_MIN / -1 overflows
        # idivq (SIGFPE) on the non-reduced lanes. Strength reduction computes
        # the defined wrap, but to keep ALL lanes trap-free, never emit a -1
        # divisor (1/-1 add nothing to coverage the pow2 path lacks).
        if _signed64(b.reg) in (1, -1) and op == "/" and _gt_is_unsigned(a.gt) is not True:
            # fall back to a safe small even divisor
            b = TV("4", _to_reg(4), typ, gt=None)
        use_signed = divshift_is_signed(a, b)
        if use_signed:
            av = _signed64(a.reg)             # %rax as signed 64-bit (idivq)
            bv = _signed64(b.reg)
            q = abs(av) // abs(bv)            # truncate toward zero (x86 idiv)
            if (av < 0) != (bv < 0):
                q = -q
            r = av - q * bv
        else:
            au = a.reg                        # %rax as unsigned 64-bit (divq)
            bu = b.reg
            q = au // bu
            r = au - q * bu
        val = q if op == "/" else r
        src = f"({a.src} {op} {b.src})"
        # Division BinaryExpr -> gt=None (no get_expr_type case).
        return TV(src, _to_reg(val), typ, gt=None)

    # ---- comparison: yields a 0/1 register; signedness of the compare is the
    #      crux of two May bugs. Backend uses an unsigned compare if EITHER
    #      operand's get_expr_type() is unsigned, else signed (codegen _rel_cc).
    def _compare(self, depth, typ):
        a = self.expr(depth - 1)
        b = self.expr(depth - 1)
        op = self.rng.choice(["<", "<=", ">", ">=", "==", "!="])
        if op in ("==", "!="):
            # eq/neq compare the full 64-bit register bits (cc e/ne).
            cmpres = (a.reg == b.reg) if op == "==" else (a.reg != b.reg)
        else:
            if cmp_is_unsigned(a, b):
                x, y = a.reg, b.reg                       # 64-bit unsigned cmp
            else:
                x, y = _signed64(a.reg), _signed64(b.reg)  # 64-bit signed cmp
            cmpres = {
                "<":  x < y, "<=": x <= y, ">": x > y, ">=": x >= y,
            }[op]
        # the 0/1 is wrapped in cast[typ] -> gt = typ.
        src = f"cast[{typ.name}]({a.src} {op} {b.src})"
        return TV(src, 1 if cmpres else 0, typ, gt=typ)

    def expr(self, depth):
        typ = self.rng.choice(ALL_TYPES)
        return self._expr_typed(depth, typ)

    def _expr_typed(self, depth, typ):
        if depth <= 0 or self.rng.random() < 0.30:
            if self.env and self.rng.random() < 0.5:
                v = self.rng.choice(self.env)
                return cast_to(v, typ)
            return self._random_literal(typ)
        kind = self.rng.random()
        if kind < 0.45:
            return self._binop(depth, typ)
        if kind < 0.65:
            return self._divmod(depth, typ)
        if kind < 0.85:
            return self._compare(depth, typ)
        inner_t = self.rng.choice(ALL_TYPES)
        inner = self._expr_typed(depth - 1, inner_t)
        return cast_to(inner, typ)

    def _random_literal(self, typ):
        choices = [
            0, 1, 2, 3, 7, 8, 15, 16, 100, 127, 128, 255, 256,
            32767, 32768, 65535, 65536,
            2147483647, 2147483648, 4294967295, 4294967296,
            -1, -2, -128, -129, -32768, -32769, -2147483648,
            9223372036854775807, 18446744073709551615,
        ]
        base = self.rng.choice(choices)
        if self.rng.random() < 0.4:
            if typ.signed:
                lo = -(1 << (typ.bits - 1)); hi = (1 << (typ.bits - 1)) - 1
            else:
                lo = 0; hi = (1 << typ.bits) - 1
            base = self.rng.randint(lo, hi)
        return lit(base, typ)


# --------------------------------------------------------------------------
# Program generator.
# --------------------------------------------------------------------------
PRELUDE = """\
# AUTO-GENERATED by tests/fuzz/adder_fuzzer.py -- do not edit.
extern def sys_write(fd: int32, buf: Ptr[uint8], count: uint64) -> int64

_ch:   Array[1, uint8]
_digs: Array[32, uint8]
g_accum: uint64

# Short-circuit observer: sc_bump() has a SIDE EFFECT (it increments g_sc) and
# returns its argument. Used as the RIGHT operand of a logical `and`/`or` so the
# test can OBSERVE whether the backend short-circuited: a correct (Python/Adder)
# short-circuit evaluation does NOT call sc_bump when the LEFT operand already
# decides the result, so g_sc stays lower. A non-short-circuit (bitwise-fold)
# backend evaluates both operands and over-increments g_sc — caught by folding
# g_sc into g_accum.
g_sc: uint64

def sc_bump(ret: int64) -> int64:
    g_sc = g_sc + cast[uint64](1)
    return ret

def _putc(c: uint8) -> int32:
    _ch[0] = c
    sys_write(cast[int32](1), &_ch[0], cast[uint64](1))
    return 0

def print_u64(val: uint64) -> int32:
    nd: int64 = 0
    v: uint64 = val
    if v == cast[uint64](0):
        _digs[0] = cast[uint8](48)
        nd = 1
    while v > cast[uint64](0):
        q: uint64 = v / cast[uint64](10)
        d: uint64 = v - q * cast[uint64](10)
        _digs[cast[int64](nd)] = cast[uint8](d + cast[uint64](48))
        nd = nd + 1
        v = q
    k: int64 = nd - 1
    while k >= 0:
        _putc(_digs[cast[int64](k)])
        k = k - 1
    _putc(cast[uint8](10))
    return 0
"""


class Program:
    # subset=True restricts the generator to the SELF-HOSTED backend
    # (codegen.ad) supported subset. As of the multi-dimensional-array-global
    # parity work, codegen.ad ALSO handles the 2-D array global + its traffic
    # (the outer index scales by the nested row stride, the inner by the
    # scalar element), so subset mode now generates byte-identically to the
    # default generator. The subset flag is retained for any FUTURE construct
    # codegen.ad does not yet handle. codegen.ad covers: 1-D/2-D/scalar
    # globals of every width, casts, compares, div/mod, loops, if/else,
    # helper calls. Used by the differential gate (tests/fuzz/
    # ad_codegen_host.py + scripts/fuzz_adder_diff.sh) so codegen.ad ACCEPTS
    # the program and its output can be compared against the predicted-output
    # oracle. subset=False (default) is byte-identical — DO NOT regress.
    def __init__(self, seed, subset=False):
        self.seed = seed
        self.subset = subset
        self.rng = random.Random(seed)
        self.lines = []
        self.toplevel = []            # struct/class defs emitted before helpers
        self.acc = 0                  # oracle: running uint64 accumulator
        self.helpers = []             # list of (name, py_callable, n_args)

    def _acc_add(self, v):
        self.acc = (self.acc + (v & umask(64))) & umask(64)

    def emit(self, s):
        self.lines.append(s)

    def emit_top(self, s):
        self.toplevel.append(s)

    def build(self):
        rng = self.rng
        # ----- struct + class definitions (top level) ------------------------
        # codegen.ad now lays out structs/classes, member load/store, method
        # dispatch + construction (Track-3 self-hosting parity). Emit these in
        # BOTH modes so the differential gate exercises them; the rng draw
        # sequence is identical across modes (the structs are always emitted).
        self._build_struct_def()
        self._build_class_def()
        self._build_multibase_def()

        # ----- globals: 2-D array + one array per store width ----------------
        rows = rng.randint(2, 4)
        cols = rng.randint(2, 4)
        # codegen.ad now supports multi-dimensional array GLOBALS (the outer
        # index scales by the nested row stride; the inner index by the
        # scalar element), so the 2-D grid is emitted in BOTH modes and the
        # differential gate exercises it. The rng draws above stay
        # unconditional so a given seed's downstream stream is identical.
        self.emit(f"g_grid: Array[{rows}, Array[{cols}, int64]]")
        self.store_arrays = {}        # type -> [name, length, py-shadow list]
        for t in STORE_TYPES:
            n = rng.randint(4, 8)
            name = f"g_{t.name}"
            self.emit(f"{name}: Array[{n}, {t.name}]")
            self.store_arrays[t] = [name, n, [0] * n]
        # scalar globals of each width — exercises the SIZED scalar-global
        # store/load path (the May "sub-8-byte write" + nested-cast bug class).
        self.scalar_globals = {}      # type -> [name, py-shadow value]
        for t in STORE_TYPES:
            name = f"s_{t.name}"
            self.emit(f"{name}: {t.name}")
            self.scalar_globals[t] = [name, 0]
        self.grid = [rows, cols, [[0] * cols for _ in range(rows)]]
        # ----- IVSR stress array: a fixed-size flat int64 array indexed by
        # affine functions of counted-loop induction variables (1-D a[i*C+R],
        # 2-D a[i*N+j], decreasing loops, multiple IVs, nested outer-invariant
        # inner indexing). The Phase-3.6 induction-variable strength-reduction
        # pass (--opt) rewrites these indices to running variables; the value
        # MUST stay bit-exact, so the by-construction checksum is the differential
        # net. Sized 16x16 = 256 so 2-D row*col addressing never overruns.
        self.ivsr_dim = 16
        self.emit(f"g_ivsr: Array[{self.ivsr_dim * self.ivsr_dim}, int64]")
        self.ivsr_shadow = [0] * (self.ivsr_dim * self.ivsr_dim)
        # DCE must-KEEP probe global: a side-effect sink the must-KEEP bait in
        # main() writes via a CALL into a NEVER-READ local. If the new per-name
        # DCE/dead-store pass wrongly deletes a call-initialized "dead-looking"
        # local, this global stops updating and the by-construction g_accum fold
        # diverges from the oracle -> the differential fuzzer flags a miscompile.
        self.emit("g_dckeep: int64")
        self.dckeep_shadow = 0
        self.emit("")

        # ----- helper functions ---------------------------------------------
        for h in range(rng.randint(1, 2)):
            self._build_helper(h)
        # A SIDE-EFFECTING helper for the DCE must-KEEP probe: it bumps the
        # g_dckeep global (an observable effect) and returns it. A local in main
        # initialized by a call to this — even if NEVER read — must be KEPT,
        # because the call's r-value is not pure (ir_lower_pure_expr rejects a
        # call), so DCE must never treat such a decl as a removable dead def.
        self.emit("def sc_dckeep_bump(v: int64) -> int64:")
        self.emit("    g_dckeep = g_dckeep + v")
        self.emit("    return g_dckeep")
        self.emit("")

        # ----- main ----------------------------------------------------------
        self.emit("def main(argc: int32, argv: Ptr[uint64]) -> int32:")
        env = []   # in-scope TV locals (src = identifier name)
        for i in range(rng.randint(2, 5)):
            t = rng.choice(ALL_TYPES)
            g = Gen(rng, env)
            e = g._expr_typed(2, t)
            name = f"l{i}"
            self.emit(f"    {name}: {t.name} = {e.src}")
            # identifier reference: reg = the value sign/zero-extended to 64
            # bits per its declared type; get_expr_type sees its type.
            env.append(TV(name, _to_reg(e.val), t, gt=t))

        self._gen_grid_traffic(env)   # 2-D array global (now codegen.ad-OK)
        self._gen_store_traffic(env)
        self._gen_index_signedness_traffic(env)  # indexed compare/shift signedness
        self._gen_aluload_traffic(env)            # memory-source ALU folds (--opt)
        self._gen_loadcse_traffic(env)            # redundant-load elimination (--opt)
        self._gen_ivsr_traffic(env)               # affine-index IV strength reduction (--opt)
        self._gen_scalar_global_traffic(env)
        self._gen_struct_traffic(env)     # struct locals: member store/read
        self._gen_class_traffic(env)      # class construction + method dispatch
        self._gen_multibase_traffic(env)  # multi-base inherited-method dispatch
        self._gen_for_range_traffic(env)  # for v in range(...)
        self._gen_for_array_traffic(env)  # for v in <array global>
        self._gen_do_while_traffic(env)   # do/while
        self._gen_float_traffic(env)      # scalar SSE float32/float64
        self._gen_loop(env)
        self._gen_nested_loop_traffic(env)    # nested loops: reset-and-read +
                                              # break/continue/early-return/cross-level
        self._gen_short_circuit_traffic(env)  # logical and/or short-circuit
        self._gen_cmpjcc_traffic(env)         # cmp; jcc branch-condition lever (--opt)
        self._gen_helper_calls(env)
        self._gen_regpressure_scratch_traffic(env)  # caller-saved IR scratch (--opt)
        self._gen_region_callsplit_traffic(env)  # per-region caller-saved regalloc (--opt)
        self._gen_dce_keep_bait(env)      # DCE in main(): fire + must-KEEP probes

        # Fold the must-KEEP global LAST so its accumulated side effect is part of
        # the checksum: any wrongly-deleted side-effecting / address-taken store
        # makes this value (and thus g_accum) diverge from the oracle.
        self._fold_value("cast[uint64](g_dckeep)", U64.wrap(I64.wrap(self.dckeep_shadow)))

        self.emit(f"    print_u64(g_accum)")
        self.emit(f"    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))")

        body = (PRELUDE + "\n"
                + "\n".join(self.toplevel) + "\n"
                + "\n".join(self.lines) + "\n")
        self.expected_stdout = str(self.acc & umask(64))
        self.expected_exit = self.acc & 0xFF
        return body

    # ---- helper: pure int function f(a,b[,c]) -> int64 -----------------------
    #
    # The helper is a convenient DCE host: a pure function whose dead-bait locals
    # exercise the fixpoint + nested-block recursion cleanly. (NOTE: DCE is no
    # longer whole-function gated on call/addr-of — opt.ad now uses a PER-NAME
    # escape check, so DCE/dead-store ALSO fires in main(); the main()-side fire +
    # must-KEEP probes live in _gen_dce_keep_bait.) We inject, behind generator
    # knobs, three optimizer-bait shapes into this pure helper, all provably
    # observationally
    # inert (they never feed `r` / the return value, so the by-construction
    # oracle `pyfn` is UNCHANGED and the equivalence assertion stays green):
    #   (1) DEAD LOCALS  — a local with a pure initializer, never read, at
    #       varying block depth; sometimes a CHAIN (a dead local whose init
    #       references an earlier dead local) so the fixpoint DCE has to iterate.
    #   (2) CONST-CONDITION BRANCHES — `if <const>:` whose condition folds to a
    #       known constant (const-fold bait) and whose body writes ONLY dead
    #       locals (so the arm is observationally empty; a future const-branch-
    #       folding pass has a dead arm to drop).
    #   (3) DEAD PURE SUBEXPRESSIONS — a dead local whose initializer is a
    #       computed pure binop tree (a value computed but never used).
    def _build_helper(self, idx):
        rng = self.rng
        name = f"helper{idx}"
        nargs = rng.randint(1, 3)
        params = [f"p{i}" for i in range(nargs)]
        sig = ", ".join(f"{p}: int64" for p in params)
        self.emit(f"def {name}({sig}) -> int64:")
        recipe = self._helper_recipe(nargs, rng)
        expr_src = self._recipe_src(recipe, params)
        self.emit(f"    r: int64 = {expr_src}")
        # Optimizer-bait dead code at TOP LEVEL of the helper (before the
        # threshold if). Names are unique per-helper so re-decls never alias.
        self._emit_dead_code(name, params, depth=0)
        thr = rng.randint(0, 50)
        self.emit(f"    if r > cast[int64]({thr}):")
        self.emit(f"        r = r - cast[int64]({thr})")
        # Optimizer-bait dead code NESTED one level deep (inside a const-true
        # branch), so DCE has to recurse into a nested block to find it.
        self._emit_dead_code(name, params, depth=1)
        self.emit("    return r")

        def pyfn(args, recipe=recipe, thr=thr):
            r = I64.wrap(self._recipe_eval(recipe, args))
            if r > thr:
                r = I64.wrap(r - thr)
            return r
        self.helpers.append((name, pyfn, nargs))

    # ---- inject observationally-inert optimizer bait into a pure function ----
    def _emit_dead_code(self, scope, params, depth):
        """Emit dead locals / const-condition branches / dead pure subexpressions
        into the CURRENT helper body. `scope` makes local names unique; `params`
        are the helper's int64 params (usable as pure-init leaves); `depth`=0 emits
        at the helper's top level, depth=1 wraps the bait in a const-true `if` so
        DCE must recurse a nested block. NONE of these locals is ever read by `r`
        or the return — they are pure-initialized and dead by construction, so the
        DCE pass removes them and the oracle (`pyfn`) is unaffected. The
        const-condition feeds the const-fold pass a foldable `1 != 0` / `0 != 0`."""
        rng = self.rng
        ind = "    " if depth == 0 else "        "
        # A monotonic per-program suffix keeps every injected name distinct
        # across helpers and depths.
        def dn():
            self._dead_seq = getattr(self, "_dead_seq", 0) + 1
            return f"dd_{scope}_{self._dead_seq}"

        # Leaves available for pure dead initializers: the helper params plus any
        # dead local already emitted in THIS call (for chaining). Constants too.
        live_leaves = list(params)
        dead_leaves = []

        def pure_init():
            # Build a small pure int64 expression from available leaves/consts.
            # Mixing in a dead leaf (when available) makes a DCE CHAIN: the new
            # dead local's init references an earlier dead local, so removing the
            # consumer must precede removing the producer (fixpoint iteration).
            def leaf():
                pool = []
                if live_leaves:
                    pool.append("live")
                if dead_leaves and rng.random() < 0.6:
                    pool.append("dead")
                pool.append("const")
                pick = rng.choice(pool)
                if pick == "live":
                    return rng.choice(live_leaves)
                if pick == "dead":
                    return rng.choice(dead_leaves)
                return f"cast[int64]({rng.randint(0, 9)})"
            node = leaf()
            for _ in range(rng.randint(0, 2)):
                op = rng.choice(["+", "-", "*", "&", "|", "^"])
                node = f"({node} {op} {leaf()})"
            return node

        if depth == 0:
            # (1)+(3) one to three dead locals at top level; the chain emerges
            # when a later init references an earlier dead leaf.
            for _ in range(rng.randint(1, 3)):
                nm = dn()
                self.emit(f"{ind}{nm}: int64 = {pure_init()}")
                dead_leaves.append(nm)
            # (4) COPY-PROP bait: a dead pure copy `cpy = <leaf>` whose dest is
            # then READ by a second dead local `use = cpy <op> <leaf>`. The read
            # of `cpy` is a pure-copy forward target — Phase-9 copy-prop rewrites
            # it to read the source directly, after which both dead locals are
            # reclaimed by DCE. Everything here is pure-initialized and read
            # nowhere by `r`/the return, so removing it (or not) is a no-op and
            # the oracle (`pyfn`) is unaffected — behavior stays identical. The
            # source is a LIVE leaf (a param or constant) so the copy is a clean
            # `dest = src` straight-line copy with no intervening write.
            src_leaf = (rng.choice(live_leaves) if live_leaves
                        else f"cast[int64]({rng.randint(0, 9)})")
            cpy = dn()
            self.emit(f"{ind}{cpy}: int64 = {src_leaf}")
            dead_leaves.append(cpy)
            other = (rng.choice(live_leaves) if live_leaves
                     else f"cast[int64]({rng.randint(0, 9)})")
            op = rng.choice(["+", "-", "*", "&", "|", "^"])
            use = dn()
            self.emit(f"{ind}{use}: int64 = ({cpy} {op} {other})")
            dead_leaves.append(use)
        else:
            # (2) const-condition branch: `if <const-true>:` whose body writes
            # ONLY dead locals — the arm is observationally empty. The condition
            # is a folded comparison so the const-fold pass has a target, and the
            # dead locals inside give DCE a NESTED block to clean. We always pick
            # a const-TRUE guard so the (empty) arm executes — still a no-op, but
            # it keeps behavior identical whether or not the optimizer folds it.
            self.emit(f"    if cast[int64](1) != cast[int64](0):")
            for _ in range(rng.randint(1, 2)):
                nm = dn()
                self.emit(f"{ind}{nm}: int64 = {pure_init()}")
                dead_leaves.append(nm)

    # ---- DCE in main(): fire + must-KEEP probes ------------------------------
    #
    # The per-name escape DCE/dead-store pass now runs in main() too (the old
    # whole-function "any call/addr-of -> bail" guard is gone). This injector
    # stresses BOTH directions in main(), which is FULL of calls and stores:
    #   FIRE — a fully-dead pure local (and a dead copy chain) whose name is read
    #          nowhere and whose address is never taken: DCE/copy-prop must be
    #          able to delete it EVEN amid the surrounding calls. Inert: never
    #          feeds g_accum, so removing it is a no-op the oracle ignores.
    #   KEEP — three shapes that MUST survive, each made observable by folding its
    #          effect into g_accum so a wrong deletion diverges from the oracle:
    #            (a) call-init: `k = sc_dckeep_bump(K)` never read — the call's
    #                side effect (g_dckeep += K) MUST run; a call r-value is not
    #                pure, so the decl must be kept.
    #            (b) address-taken local: `&m` escapes, then m is READ THROUGH the
    #                pointer — never-read-by-name but observed; must be kept.
    #            (c) later-read store: `n = A; n = B; <read n>` — the first store
    #                is dead but partial liveness is not modelled and n IS read,
    #                so the global-unused proof fails and nothing is removed.
    def _gen_dce_keep_bait(self, env):
        rng = self.rng
        self._dckeep_seq = getattr(self, "_dckeep_seq", 0) + 1
        u = self._dckeep_seq

        # FIRE: a fully-dead pure local + a dead copy chain, all read nowhere and
        # never address-taken — DCE/copy-prop should delete them amid main()'s
        # calls. Pure init over a constant so there is no live dependency.
        base = rng.randint(1, 99)
        self.emit(f"    dkdead_{u}: int64 = cast[int64]({base}) * cast[int64](3)")
        self.emit(f"    dkcpy_{u}: int64 = dkdead_{u}")          # dead copy
        self.emit(f"    dkcpy2_{u}: int64 = dkcpy_{u}")          # forwarded chain
        self.emit(f"    dkuse_{u}: int64 = dkcpy2_{u} + cast[int64](1)")  # dead consumer
        # (inert: none of dkdead/dkcpy/dkcpy2/dkuse is read after here)

        # KEEP (a): call-init never read -> side effect on g_dckeep must persist.
        ka = rng.randint(1, 1000)
        self.emit(f"    dkkeep_{u}: int64 = sc_dckeep_bump(cast[int64]({ka}))")
        self.dckeep_shadow = I64.wrap(self.dckeep_shadow + ka)

        # KEEP (b): address-taken local, read through the pointer. Folded so the
        # observed value pins it; if DCE wrongly dropped `m`, p[0] reads garbage.
        mv = rng.randint(1, 1000)
        self.emit(f"    dkm_{u}: int64 = cast[int64]({mv})")
        self.emit(f"    dkp_{u}: Ptr[int64] = &dkm_{u}")
        self._fold_value(f"cast[uint64](dkp_{u}[0])", U64.wrap(I64.wrap(mv)))

        # KEEP (c): later-read store. n = A (dead store) ; n = B ; read n == B.
        a_val = rng.randint(1, 1000)
        b_val = rng.randint(1, 1000)
        self.emit(f"    dkn_{u}: int64 = cast[int64]({a_val})")
        self.emit(f"    dkn_{u} = cast[int64]({b_val})")
        self._fold_value(f"cast[uint64](dkn_{u})", U64.wrap(I64.wrap(b_val)))

    def _helper_recipe(self, nargs, rng):
        ops = ["+", "-", "*"]
        node = ("p", rng.randrange(nargs))
        for _ in range(rng.randint(1, 3)):
            op = rng.choice(ops)
            if rng.random() < 0.5:
                rhs = ("p", rng.randrange(nargs))
            else:
                rhs = ("c", rng.randint(1, 7))
            node = (op, node, rhs)
        return node

    def _recipe_src(self, node, params):
        tag = node[0]
        if tag == "p":
            return params[node[1]]
        if tag == "c":
            return f"cast[int64]({node[1]})"
        return (f"({self._recipe_src(node[1], params)} {tag} "
                f"{self._recipe_src(node[2], params)})")

    def _recipe_eval(self, node, args):
        tag = node[0]
        if tag == "p":
            return args[node[1]]
        if tag == "c":
            return node[1]
        a = self._recipe_eval(node[1], args)
        b = self._recipe_eval(node[2], args)
        return {"+": a + b, "-": a - b, "*": a * b}[tag]

    # ---- 2-D array store/read traffic ----------------------------------------
    def _gen_grid_traffic(self, env):
        rng = self.rng
        rows, cols, shadow = self.grid
        for _ in range(rng.randint(2, 5)):
            r = rng.randrange(rows); c = rng.randrange(cols)
            g = Gen(rng, env)
            e = g._expr_typed(2, I64)
            self.emit(f"    g_grid[{r}][{c}] = {e.src}")
            shadow[r][c] = I64.wrap(e.val)
        for _ in range(rng.randint(2, 4)):
            r = rng.randrange(rows); c = rng.randrange(cols)
            self._fold_value(f"cast[uint64](g_grid[{r}][{c}])", shadow[r][c])

    # ---- sub-word store/read traffic ----------------------------------------
    def _gen_store_traffic(self, env):
        rng = self.rng
        for t in STORE_TYPES:
            name, n, shadow = self.store_arrays[t]
            for _ in range(rng.randint(1, 3)):
                idx = rng.randrange(n)
                g = Gen(rng, env)
                e = g._expr_typed(2, t)
                self.emit(f"    {name}[{idx}] = {e.src}")
                shadow[idx] = t.wrap(e.val)
            idx = rng.randrange(n)
            stored = shadow[idx]
            # widening to uint64 reinterprets via the element type's signedness
            self._fold_value(
                f"cast[uint64](cast[{t.name}]({name}[{idx}]))",
                U64.wrap(stored))
            # SIGN-FAITHFUL read (no inner cast[T]): the index LOAD itself must
            # sign-extend a signed sub-8-byte element / zero-extend an unsigned
            # one. The inner cast[T] above re-extends and so MASKS a wrong load
            # extension; this fold observes the load's own extension directly.
            # shadow[idx] is the type-view value (negative for a signed elem);
            # _to_reg widens it into the 64-bit register exactly as the correct
            # load would. A blind movq / wrong-signedness extend diverges here.
            idx2 = rng.randrange(n)
            self._fold_value(
                f"cast[uint64]({name}[{idx2}])",
                U64.wrap(_to_reg(shadow[idx2])))

    # ---- indexed-element compare / shift SIGNEDNESS traffic ------------------
    def _gen_index_signedness_traffic(self, env):
        """Compare and right-shift an ARRAY ELEMENT against a constant. The
        machine compare (setcc family) and `>>` (sar vs shr) MUST use the
        ELEMENT TYPE's signedness — the seed resolves it via
        get_expr_type(IndexExpr)->element_type; codegen.ad must match via
        expr_signedness(ND_INDEX). A SIGNED element near its sign boundary makes
        a wrong unsigned compare/shift diverge, and an UNSIGNED element with the
        high bit set makes a wrong signed compare/shift diverge. We fold the 0/1
        compare result and the shifted value into g_accum so either error breaks
        the by-construction oracle. Both subset and default mode identical."""
        rng = self.rng
        for ti, t in enumerate(STORE_TYPES):
            name, n, shadow = self.store_arrays[t]
            # Unique per-iteration local names — re-declaring one name (`ish`)
            # with DIFFERENT widths across iterations is an ambiguous shadowing
            # the two backends need not lower identically, and is not the
            # construct under test. Distinct names keep the slot typing clean.
            icbv = f"icb_{ti}"
            ishv = f"ish_{ti}"
            # Plant an element with the high bit set so signed/unsigned differ.
            idx = rng.randrange(n)
            hi = (1 << (t.bits - 1))
            raw = hi | rng.randint(0, hi - 1)        # high bit set
            self.emit(f"    {name}[{idx}] = cast[{t.name}]({raw})")
            shadow[idx] = t.wrap(raw)
            ev = _to_reg(shadow[idx])                 # 64-bit register view
            # (1) compare `elem < K` — signedness-sensitive when high bit set.
            K = rng.randint(0, (1 << t.bits) - 1)
            # oracle: compare as the element type's signedness
            if t.signed:
                lhs = shadow[idx]
                rhs = K - (1 << t.bits) if K >= hi else K
                res = 1 if lhs < rhs else 0
            else:
                res = 1 if (ev & umask(64)) < K else 0
            self.emit(f"    {icbv}: int64 = cast[int64](0)")
            self.emit(f"    if {name}[{idx}] < cast[{t.name}]({K}):")
            self.emit(f"        {icbv} = cast[int64](1)")
            self._fold_value(f"cast[uint64]({icbv})", U64.wrap(res))
            # (2) right-shift `elem >> s` — sar (signed) vs shr (unsigned).
            s = rng.randint(1, t.bits - 1)
            if t.signed:
                # arithmetic shift of the type-view (sign-propagating) value
                v = shadow[idx]
                sh = v >> s
            else:
                sh = (ev & umask(t.bits)) >> s
            self.emit(f"    {ishv}: {t.name} = {name}[{idx}] >> cast[{t.name}]({s})")
            self._fold_value(f"cast[uint64](cast[{t.name}]({ishv}))",
                             U64.wrap(t.wrap(sh)))
        # 8-byte GLOBAL signed-vs-unsigned DIVISION + COMPARE. An int64 global
        # divided/compared must use idiv/cqto + signed setcc; a uint64 global
        # div/xor + unsigned setcc. expr_signedness for an 8-byte global must
        # report its FULL declared signedness (glob_signedness), not the
        # sub-8-byte load-extension flag. A wrong choice diverges from the
        # oracle. (s_int64 / s_uint64 are declared scalar globals.)
        for tn, signed in (("int64", True), ("uint64", False)):
            gname = f"s_{tn}"
            num = rng.randint(-(1 << 40), (1 << 40)) if signed \
                else rng.randint(0, (1 << 41))
            den = rng.choice([d for d in (3, 7, 13, -5) if signed or d > 0])
            self.emit(f"    {gname} = cast[{tn}]({num})")
            qn = f"q_{tn}"
            self.emit(f"    {qn}: {tn} = {gname} / cast[{tn}]({den})")
            if signed:
                # Python // floors; Adder/C signed div truncates toward zero.
                a, b = num, den
                q = abs(a) // abs(b)
                if (a < 0) != (b < 0):
                    q = -q
                self._fold_value(f"cast[uint64](cast[{tn}]({qn}))", U64.wrap(I64.wrap(q)))
                cres = 1 if num < den else 0
            else:
                un = num & umask(64)
                q = un // den
                self._fold_value(f"cast[uint64]({qn})", U64.wrap(q))
                cres = 1 if un < (den & umask(64)) else 0
            cbn = f"cb_{tn}"
            self.emit(f"    {cbn}: int64 = cast[int64](0)")
            self.emit(f"    if {gname} < cast[{tn}]({den}):")
            self.emit(f"        {cbn} = cast[int64](1)")
            self._fold_value(f"cast[uint64]({cbn})", U64.wrap(cres))

    # ---- ALU memory-source operand traffic (--opt alu-load fold) -------------
    def _gen_aluload_traffic(self, env):
        """Feed an 8-byte INTEGER array element DIRECTLY into an ALU op as the
        RIGHT operand: `local OP arr[i]`, `arr[i] OP arr[j]` (two memory
        sources on a single op), and an element-vs-local compare. Under --opt
        these source the element in-place via `op (%rcx),%rax` (the alu-load
        fold); the seed loads-to-temp then combines. The VALUE must be bit-exact
        either way. 8-byte int64/uint64 elements only: that is exactly the
        foldable width (a full-width fetch with no extension hazard), so this is
        the differential check for the fold. Each result folds into g_accum so a
        wrong addressing mode / clobbered operand breaks the by-construction
        oracle. Identical in subset and default mode (same rng stream)."""
        rng = self.rng
        # The 8-byte int store arrays (int64 / uint64) — the only foldable width.
        for ti, t in enumerate((I64, U64)):
            name, n, shadow = self.store_arrays[t]
            # Plant two distinct element values (one near the type's sign
            # boundary so signed/unsigned MUL/ADD wraparound is exercised).
            ia = rng.randrange(n)
            ib = rng.randrange(n)
            if ib == ia:
                ib = (ib + 1) % n
            hi = (1 << (t.bits - 1))
            va = (hi | rng.randint(0, hi - 1)) if rng.random() < 0.5 \
                else rng.randint(0, hi - 1)
            vb = rng.randint(0, (1 << t.bits) - 1)
            self.emit(f"    {name}[{ia}] = cast[{t.name}]({va})")
            self.emit(f"    {name}[{ib}] = cast[{t.name}]({vb})")
            shadow[ia] = t.wrap(va)
            shadow[ib] = t.wrap(vb)
            ea = _to_reg(shadow[ia])          # 64-bit register view of element a
            eb = _to_reg(shadow[ib])
            # A scalar local operand value (the LEFT side of `local OP arr[i]`).
            lv = rng.randint(0, (1 << 40))
            lreg = _to_reg(t.wrap(lv))
            # (1) local OP arr[ia] — RIGHT operand is the memory element.
            #     ADD/SUB/MUL/AND/OR/XOR all source the element in-place. A
            #     fresh per-op local holds the left value so each line is a
            #     clean `local OP elem`.
            opcnt = 0
            for opn, pyf in (
                ("+", lambda x, y: x + y),
                ("-", lambda x, y: x - y),
                ("*", lambda x, y: x * y),
                ("&", lambda x, y: x & y),
                ("|", lambda x, y: x | y),
                ("^", lambda x, y: x ^ y),
            ):
                opl = f"al_{ti}_{opcnt}"
                accl = f"alr_{ti}_{opcnt}"
                opcnt = opcnt + 1
                self.emit(f"    {opl}: {t.name} = cast[{t.name}]({lv})")
                # Assign the BARE `local OP elem` binop to a SAME-TYPE local: with
                # no inner cast wrapping the op, the binop is an IR root and the
                # memory element sources in-place (the fold FIRES). Width is 64 so
                # the store is value-preserving; read back with one outer cast.
                self.emit(f"    {accl}: {t.name} = {opl} {opn} {name}[{ia}]")
                # Adder computes in full 64-bit registers; the {t.name} store
                # (width 64) then wraps to the type. Operate on raw register views.
                res = t.wrap(pyf(lreg, ea))
                self._fold_value(f"cast[uint64]({accl})", U64.wrap(res))
            # (2) arr[ia] OP arr[ib] — BOTH operands are memory elements; the
            #     RIGHT one is folded as the in-place memory source. MUL here
            #     exercises imulq (%rcx),%rax with the left also memory-loaded.
            mc = 0
            for opn, pyf in (
                ("+", lambda x, y: x + y),
                ("*", lambda x, y: x * y),
                ("^", lambda x, y: x ^ y),
            ):
                mcl = f"alm_{ti}_{mc}"
                mc = mc + 1
                self.emit(f"    {mcl}: {t.name} = {name}[{ia}] {opn} {name}[{ib}]")
                res = t.wrap(pyf(ea, eb))
                self._fold_value(f"cast[uint64]({mcl})", U64.wrap(res))
            # (3) compare local < arr[ia] — directional, signedness from element
            #     type. cmpq (%rcx),%rax + setcc must match the reg-reg compare.
            cbn = f"alc_{ti}"
            self.emit(f"    {cbn}: int64 = cast[int64](0)")
            self.emit(f"    if cast[{t.name}]({lv}) < {name}[{ia}]:")
            self.emit(f"        {cbn} = cast[int64](1)")
            if t.signed:
                cres = 1 if I64.wrap(lv) < shadow[ia] else 0
            else:
                cres = 1 if (lreg & umask(64)) < (ea & umask(64)) else 0
            self._fold_value(f"cast[uint64]({cbn})", U64.wrap(cres))

    # ---- redundant-load (load-CSE) traffic -----------------------------------
    def _gen_loadcse_traffic(self, env):
        """Stress the cross-statement LOAD-CSE broadening (--opt): a redundant
        integer array element load reuses an earlier identical load's value via a
        hoisted temp — UNLESS an intervening store (to the same OR an aliasing
        index) or a write to the index variable could change the location. The
        oracle (Python shadow) is authoritative; under --opt a WRONG reuse returns
        a STALE value and breaks g_accum, while the seed and the OFF path always
        recompute. Every shape below is byte-identical in subset and default mode
        (same rng stream), and the index variable `lc_i` is a real LOCAL so the
        load address depends on a name the store-kill / name-kill paths exercise.

        Shapes:
          (A) Same element read 3x across adjacent decls, NO intervening store →
              the 2nd and 3rd reads MUST be CSE'd. Value = element each time.
          (B) read, then an ALIASING store to the SAME element, then re-read →
              the re-read MUST NOT be CSE'd; it sees the NEW value (store-kill).
          (C) read arr[i], then a store to a DIFFERENT, possibly-aliasing index
              arr[j] (an opaque index store = hard barrier) then re-read arr[i] →
              re-read MUST NOT reuse (the barrier flushed availability). Here j!=i
              so arr[i] is unchanged, but the optimizer cannot prove j!=i, so it
              must conservatively recompute — value is the ORIGINAL element.
          (D) read arr[i], then REASSIGN i, then read arr[i] → different element,
              MUST NOT reuse (name-kill on the index variable).
        """
        rng = self.rng
        name, n, shadow = self.store_arrays[I64]
        # Pick two distinct indices.
        ia = rng.randrange(n)
        ib = rng.randrange(n)
        if ib == ia:
            ib = (ib + 1) % n
        va = rng.randint(-(1 << 40), (1 << 40))
        vb = rng.randint(-(1 << 40), (1 << 40))
        self.emit(f"    {name}[{ia}] = cast[int64]({va})")
        self.emit(f"    {name}[{ib}] = cast[int64]({vb})")
        shadow[ia] = I64.wrap(va)
        shadow[ib] = I64.wrap(vb)
        ea = _to_reg(shadow[ia])
        eb = _to_reg(shadow[ib])
        # Index variable as a real local so its read drives the load address.
        self.emit(f"    lc_i: int64 = cast[int64]({ia})")

        # (A) three redundant reads of arr[lc_i], no intervening store.
        for r in range(3):
            self.emit(f"    lcA_{r}: int64 = {name}[cast[int64](lc_i)] + cast[int64]({r})")
            self._fold_value(f"cast[uint64](lcA_{r})", U64.wrap((ea + r)))

        # (B) read, aliasing store to the SAME element, re-read (store-kill).
        self.emit(f"    lcB0: int64 = {name}[cast[int64](lc_i)] + cast[int64](1)")
        self._fold_value("cast[uint64](lcB0)", U64.wrap((ea + 1)))
        vnew = rng.randint(-(1 << 40), (1 << 40))
        self.emit(f"    {name}[cast[int64](lc_i)] = cast[int64]({vnew})")
        shadow[ia] = I64.wrap(vnew)
        ea = _to_reg(shadow[ia])
        self.emit(f"    lcB1: int64 = {name}[cast[int64](lc_i)] + cast[int64](1)")
        self._fold_value("cast[uint64](lcB1)", U64.wrap((ea + 1)))

        # (C) read arr[ia], opaque store to arr[ib] (barrier), re-read arr[ia].
        self.emit(f"    lcC0: int64 = {name}[cast[int64](lc_i)] + cast[int64](2)")
        self._fold_value("cast[uint64](lcC0)", U64.wrap((ea + 2)))
        vc = rng.randint(-(1 << 40), (1 << 40))
        self.emit(f"    {name}[{ib}] = cast[int64]({vc})")
        shadow[ib] = I64.wrap(vc)
        eb = _to_reg(shadow[ib])
        self.emit(f"    lcC1: int64 = {name}[cast[int64](lc_i)] + cast[int64](2)")
        self._fold_value("cast[uint64](lcC1)", U64.wrap((ea + 2)))   # arr[ia] unchanged

        # (D) read arr[lc_i], reassign lc_i to ib, read arr[lc_i] (name-kill).
        self.emit(f"    lcD0: int64 = {name}[cast[int64](lc_i)] + cast[int64](3)")
        self._fold_value("cast[uint64](lcD0)", U64.wrap((ea + 3)))
        self.emit(f"    lc_i = cast[int64]({ib})")
        self.emit(f"    lcD1: int64 = {name}[cast[int64](lc_i)] + cast[int64](3)")
        self._fold_value("cast[uint64](lcD1)", U64.wrap((eb + 3)))

    # ---- scalar-global store/read traffic ------------------------------------
    def _gen_scalar_global_traffic(self, env):
        rng = self.rng
        for t in STORE_TYPES:
            name, _ = self.scalar_globals[t]
            g = Gen(rng, env)
            e = g._expr_typed(2, t)
            self.emit(f"    {name} = {e.src}")
            stored = t.wrap(e.val)         # sized store truncates to t
            self.scalar_globals[t][1] = stored
            # read back widened to uint64 via the global's declared signedness.
            # NOTE: a bare `cast[uint64](name)` (no inner cast[T]) already
            # observes the GLOBAL LOAD's own extension directly — there is no
            # masking inner cast here — so this single fold exercises the
            # scalar-global load sign/zero-extension faithfully. stored is the
            # type-view value (negative for a signed global); _to_reg widens it
            # into the register exactly as a correct sign/zero-extending load.
            self._fold_value(f"cast[uint64]({name})", U64.wrap(_to_reg(stored)))

    # ---- counted loop with a conditional body --------------------------------
    # ---- IVSR-targeted affine-index loop traffic (--opt Phase 3.6) -----------
    #
    # Stresses induction-variable strength reduction: counted loops that index a
    # flat int64 array global by an AFFINE function of the loop counter, the exact
    # shape the pass rewrites into a pre-header-seeded running variable. Every
    # shape is simulated bit-exactly in Python (int64 wraparound via I64.wrap) and
    # the resulting array contents are folded into g_accum, so any divergence
    # between the original index and the strength-reduced running variable BREAKS
    # the by-construction oracle (the differential ADDER_OPT=1 lane catches it).
    #
    # Shapes (biased HARD toward loop+index forms per the IVSR risk profile):
    #   * 1-D  a[i*C + R]      constant coefficient C, invariant remainder R
    #   * 2-D  a[i*N + j]      runtime-invariant row coefficient N (the matmul win)
    #   * step != 1 / decreasing loops (i -= s, i = i - s)
    #   * nested loop where the OUTER iv is invariant in the inner (a[i*N + j])
    #   * multiple independent affine indices over the SAME iv (grouped to one
    #     running var when value-equal, separate when not)
    #   * pointer ALIAS of the indexed array (cast to Ptr) read back to confirm
    #     the running-variable store landed at the same address
    #   * early-exit / break inside the counted loop
    def _gen_ivsr_traffic(self, env):
        rng = self.rng
        if not hasattr(self, "_ivsr_uid"):
            self._ivsr_uid = 0
        D = self.ivsr_dim
        NCELL = D * D
        arr = "g_ivsr"
        sh = self.ivsr_shadow

        def store(idx, val):
            idx &= (NCELL - 1) if (NCELL & (NCELL - 1)) == 0 else 0xFFFFFFFF
            idx %= NCELL
            v = I64.wrap(val)
            sh[idx] = v
            return idx, v

        for _ in range(rng.randint(3, 5)):
            self._ivsr_uid += 1
            u = self._ivsr_uid
            shape = rng.choice([
                "lin1d", "lin1d_R", "twod", "dec", "stepk",
                "nested_outer_inv", "multi_iv_index", "alias", "break_exit",
            ])
            if shape == "lin1d":
                # a[i*C] = i*7 + C  for i in 0..n, C constant >= 2.
                C = rng.randint(2, 5)
                n = rng.randint(2, D // C if D // C >= 2 else 2)
                self.emit(f"    iva_{u}: int64 = cast[int64](0)")
                self.emit(f"    while iva_{u} < cast[int64]({n}):")
                self.emit(f"        {arr}[cast[int64](iva_{u} * {C})] = "
                          f"iva_{u} * cast[int64](7) + cast[int64]({C})")
                self.emit(f"        iva_{u} = iva_{u} + cast[int64](1)")
                for i in range(n):
                    store(i * C, I64.wrap(i * 7 + C))
            elif shape == "lin1d_R":
                # a[i*C + R] = i - R   (R invariant local)
                C = rng.randint(2, 4)
                R = rng.randint(0, 3)
                n = rng.randint(2, max(2, (D - R) // C))
                self.emit(f"    ivr_{u}: int64 = cast[int64]({R})")
                self.emit(f"    ivb_{u}: int64 = cast[int64](0)")
                self.emit(f"    while ivb_{u} < cast[int64]({n}):")
                self.emit(f"        {arr}[cast[int64](ivb_{u} * {C} + ivr_{u})] = "
                          f"ivb_{u} - ivr_{u}")
                self.emit(f"        ivb_{u} = ivb_{u} + cast[int64](1)")
                for i in range(n):
                    store(i * C + R, I64.wrap(i - R))
            elif shape == "twod":
                # 2-D: a[i*N + j] over a nested loop, N a runtime-invariant local.
                N = D
                ni = rng.randint(2, 4)
                nj = rng.randint(2, 4)
                self.emit(f"    ivN_{u}: int64 = cast[int64]({N})")
                self.emit(f"    ivi_{u}: int64 = cast[int64](0)")
                self.emit(f"    while ivi_{u} < cast[int64]({ni}):")
                self.emit(f"        ivj_{u}: int64 = cast[int64](0)")
                self.emit(f"        while ivj_{u} < cast[int64]({nj}):")
                self.emit(f"            {arr}[cast[int64](ivi_{u} * ivN_{u} + ivj_{u})] = "
                          f"ivi_{u} * cast[int64](3) + ivj_{u}")
                self.emit(f"            ivj_{u} = ivj_{u} + cast[int64](1)")
                self.emit(f"        ivi_{u} = ivi_{u} + cast[int64](1)")
                for i in range(ni):
                    for j in range(nj):
                        store(i * N + j, I64.wrap(i * 3 + j))
            elif shape == "dec":
                # Decreasing loop: i goes n-1 .. 0, index i*C.
                C = rng.randint(2, 4)
                n = rng.randint(2, max(2, D // C))
                self.emit(f"    ivd_{u}: int64 = cast[int64]({n - 1})")
                self.emit(f"    while ivd_{u} >= cast[int64](0):")
                self.emit(f"        {arr}[cast[int64](ivd_{u} * {C})] = "
                          f"ivd_{u} + cast[int64](2)")
                self.emit(f"        ivd_{u} = ivd_{u} - cast[int64](1)")
                for i in range(n - 1, -1, -1):
                    store(i * C, I64.wrap(i + 2))
            elif shape == "stepk":
                # Step != 1: i advances by s; index i*C. Running var advances C*s.
                C = rng.randint(2, 3)
                s = rng.randint(2, 3)
                n = rng.randint(2, max(2, D // (C * s)))
                self.emit(f"    ivs_{u}: int64 = cast[int64](0)")
                self.emit(f"    ivc_{u}: int64 = cast[int64](0)")
                self.emit(f"    while ivc_{u} < cast[int64]({n}):")
                self.emit(f"        {arr}[cast[int64](ivs_{u} * {C})] = "
                          f"ivs_{u} + cast[int64](5)")
                self.emit(f"        ivs_{u} = ivs_{u} + cast[int64]({s})")
                self.emit(f"        ivc_{u} = ivc_{u} + cast[int64](1)")
                iv = 0
                for _c in range(n):
                    store(iv * C, I64.wrap(iv + 5))
                    iv += s
            elif shape == "nested_outer_inv":
                # Inner loop where the OUTER iv contributes an invariant i*N base:
                # a[i*N + j] with i fixed across the inner j-loop.
                N = D
                ni = rng.randint(2, 3)
                nj = rng.randint(2, 4)
                self.emit(f"    ivM_{u}: int64 = cast[int64]({N})")
                self.emit(f"    ivoi_{u}: int64 = cast[int64](0)")
                self.emit(f"    while ivoi_{u} < cast[int64]({ni}):")
                self.emit(f"        ivij_{u}: int64 = cast[int64](0)")
                self.emit(f"        while ivij_{u} < cast[int64]({nj}):")
                self.emit(f"            {arr}[cast[int64](ivoi_{u} * ivM_{u} + ivij_{u} * 2)] = "
                          f"ivoi_{u} + ivij_{u}")
                self.emit(f"            ivij_{u} = ivij_{u} + cast[int64](1)")
                self.emit(f"        ivoi_{u} = ivoi_{u} + cast[int64](1)")
                for i in range(ni):
                    for j in range(nj):
                        if i * N + j * 2 < NCELL:
                            store(i * N + j * 2, I64.wrap(i + j))
            elif shape == "multi_iv_index":
                # Two DISTINCT affine indices over the same iv in one body:
                # a[i*2] and a[i*3 + 1] — separate running variables.
                n = rng.randint(2, 4)
                self.emit(f"    ivm_{u}: int64 = cast[int64](0)")
                self.emit(f"    while ivm_{u} < cast[int64]({n}):")
                self.emit(f"        {arr}[cast[int64](ivm_{u} * 2)] = "
                          f"ivm_{u} + cast[int64](1)")
                self.emit(f"        {arr}[cast[int64](ivm_{u} * 3 + 1)] = "
                          f"ivm_{u} * cast[int64](4)")
                self.emit(f"        ivm_{u} = ivm_{u} + cast[int64](1)")
                for i in range(n):
                    store(i * 2, I64.wrap(i + 1))
                    store(i * 3 + 1, I64.wrap(i * 4))
            elif shape == "alias":
                # Write via a[i*C], then read back via a Ptr alias to confirm the
                # running-variable store address matches the indexed one.
                C = rng.randint(2, 4)
                n = rng.randint(2, max(2, D // C))
                self.emit(f"    ival_{u}: int64 = cast[int64](0)")
                self.emit(f"    while ival_{u} < cast[int64]({n}):")
                self.emit(f"        {arr}[cast[int64](ival_{u} * {C})] = "
                          f"ival_{u} + cast[int64](9)")
                self.emit(f"        ival_{u} = ival_{u} + cast[int64](1)")
                self.emit(f"        ivalp_{u}: Ptr[int64] = cast[Ptr[int64]](&{arr}[0])")
                # read back the LAST written cell through the alias and fold it
                last = (n - 1) * C
                self.emit(f"    ivalp2_{u}: Ptr[int64] = cast[Ptr[int64]](&{arr}[0])")
                self.emit(f"    ivalrd_{u}: int64 = ivalp2_{u}[cast[int64]({last})]")
                for i in range(n):
                    store(i * C, I64.wrap(i + 9))
                self._fold_value(f"cast[uint64](ivalrd_{u})", U64.wrap(sh[last % NCELL]))
            else:  # break_exit
                # Counted loop with an early break: a[i*C] until i==brk.
                C = rng.randint(2, 4)
                n = rng.randint(3, max(3, D // C))
                brk = rng.randint(1, n - 1)
                self.emit(f"    ivbk_{u}: int64 = cast[int64](0)")
                self.emit(f"    while ivbk_{u} < cast[int64]({n}):")
                self.emit(f"        if ivbk_{u} == cast[int64]({brk}):")
                self.emit(f"            break")
                self.emit(f"        {arr}[cast[int64](ivbk_{u} * {C})] = "
                          f"ivbk_{u} + cast[int64](3)")
                self.emit(f"        ivbk_{u} = ivbk_{u} + cast[int64](1)")
                for i in range(n):
                    if i == brk:
                        break
                    store(i * C, I64.wrap(i + 3))

        # Fold the WHOLE array's contents into g_accum so every strength-reduced
        # store is differentially checked. A position-weighted sum makes a
        # mislanded store (wrong address from a bad running var) diverge.
        self.emit(f"    ivsum_{u}: int64 = cast[int64](0)")
        self.emit(f"    ivk_{u}: int64 = cast[int64](0)")
        self.emit(f"    while ivk_{u} < cast[int64]({NCELL}):")
        self.emit(f"        ivsum_{u} = ivsum_{u} + {arr}[cast[int64](ivk_{u})] * "
                  f"(ivk_{u} + cast[int64](1))")
        self.emit(f"        ivk_{u} = ivk_{u} + cast[int64](1)")
        total = 0
        for k in range(NCELL):
            total = I64.wrap(total + I64.wrap(sh[k] * (k + 1)))
        self._fold_value(f"cast[uint64](ivsum_{u})", U64.wrap(total))

    def _gen_loop(self, env):
        rng = self.rng
        n = rng.randint(3, 12)
        step = rng.randint(1, 5)
        thr = rng.randint(0, n)
        self.emit(f"    li: int64 = 0")
        self.emit(f"    lsum: uint64 = cast[uint64](0)")
        self.emit(f"    while li < cast[int64]({n}):")
        self.emit(f"        if li < cast[int64]({thr}):")
        self.emit(f"            lsum = lsum + cast[uint64](li * cast[int64]({step}))")
        self.emit(f"        else:")
        self.emit(f"            lsum = lsum + cast[uint64](li)")
        self.emit(f"        li = li + 1")
        lsum = 0
        for li in range(n):
            lsum += I64.wrap(li * step) if li < thr else li
            lsum &= umask(64)
        self._fold_value("lsum", lsum)

    # ---- nested-loop traffic (reset-and-read + general nested control flow) ---
    #
    # Exercises the control-flow shape that the bench (docs/bench_opt_results.md)
    # found MISCOMPILED under ADDER_OPT=1: an inner loop sitting BETWEEN a local's
    # def and its read across outer-loop iterations. The earlier `_gen_loop` only
    # emitted a SINGLE flat loop with a straight-line body, so the register
    # allocator's program-point numbering bug (a block CREATED before it is FILLED
    # — a while's exit/join block — getting a stale `bb_first` snapshot that placed
    # its span INSIDE the loop body, truncating a live-through value's range) was
    # never triggered. These shapes force nested loops, loops inside ifs,
    # break/continue in nested loops, an early return guarded so it stays
    # deterministic, and accumulators mutated across nesting levels. Every shape is
    # simulated exactly in Python and folded into g_accum, so the by-construction
    # oracle has ground truth and any miscompile DIVERGES.
    #
    # All locals get a per-call unique suffix so repeated invocations / other
    # generators never collide on a name.
    def _gen_nested_loop_traffic(self, env):
        rng = self.rng
        if not hasattr(self, "_nl_uid"):
            self._nl_uid = 0
        # Emit between 2 and 4 distinct nested-loop shapes. Each shape is a
        # SELF-CONTAINED HELPER FUNCTION with FEW locals, then CALLED from main
        # with the result folded into g_accum. Isolating each shape in its own
        # low-pressure function is what makes the register-allocator bug FIRE
        # DETERMINISTICALLY: the bug truncates a loop-spanning local's live range
        # so a LATER value reuses its register; in a huge main() full of locals
        # the truncated value may not collide / may be spilled, masking it. A
        # tight helper guarantees the live-through accumulator and the loop
        # counter want the same callee-saved register, so the collision shows.
        for _ in range(rng.randint(2, 4)):
            shape = rng.choice([
                "reset_read",       # the exact bench-failing shape
                "loop_in_if",       # loop nested inside an if inside a loop
                "break_continue",   # break/continue inside the inner loop
                "early_return_acc", # early return out of nested loops
                "cross_level_acc",  # accumulator mutated across nesting levels
                "loopcarry",        # matmul-shaped: multi-IV reduction whose
                                    # carried scalar is named TWICE per statement
                                    # (use-vector dedup) + a redeclared-per-
                                    # iteration local seeded from a DISTINCT value
                                    # (must NOT be wrongly coalesced)
            ])
            self._nl_uid += 1
            u = self._nl_uid
            if shape == "reset_read":
                self._nl_reset_read(u)
            elif shape == "loop_in_if":
                self._nl_loop_in_if(u)
            elif shape == "break_continue":
                self._nl_break_continue(u)
            elif shape == "early_return_acc":
                self._nl_early_return(u)
            elif shape == "loopcarry":
                self._nl_loopcarry(u)
            else:
                self._nl_cross_level(u)

    # Helper that emits a standalone int64 function `fn` (its body lines already
    # built) and a call to it from main, folding the returned value (computed by
    # the oracle `res`) into g_accum.
    def _nl_emit_helper(self, fn, sig, body_lines, call_args, res):
        self.emit_top(f"def {fn}({sig}) -> int64:")
        for ln in body_lines:
            self.emit_top("    " + ln)
        self.emit_top("")
        hc = f"{fn}_v"
        self.emit(f"    {hc}: int64 = {fn}({call_args})")
        self._fold_value(f"cast[uint64]({hc})", U64.wrap(res))

    # Exact bench repro shape: outer loop; a LOCAL re-initialised each outer pass,
    # an INNER loop that mutates it, then a READ after the inner loop.
    def _nl_reset_read(self, u):
        rng = self.rng
        reps = rng.randint(2, 6); inner = rng.randint(1, 7)
        base = rng.randint(0, 5); step = rng.randint(1, 4)
        fn = f"nl_rr_{u}"
        body = [
            "acc: int64 = cast[int64](0)",
            "r: int64 = cast[int64](0)",
            "while r < reps:",
            "    cnt: int64 = base",
            "    i: int64 = cast[int64](0)",
            "    while i < inner:",
            "        cnt = cnt + step",
            "        i = i + cast[int64](1)",
            "    acc = acc + cnt",
            "    r = r + cast[int64](1)",
            "return acc",
        ]
        acc = 0
        for _r in range(reps):
            cnt = base
            for _i in range(inner):
                cnt += step
            acc += cnt
        self._nl_emit_helper(
            fn, "reps: int64, inner: int64, base: int64, step: int64", body,
            f"cast[int64]({reps}), cast[int64]({inner}), "
            f"cast[int64]({base}), cast[int64]({step})", acc)

    # Inner loop nested inside an `if` inside the outer loop.
    def _nl_loop_in_if(self, u):
        rng = self.rng
        reps = rng.randint(3, 7); inner = rng.randint(1, 5)
        thr = rng.randint(0, reps)
        fn = f"nl_lif_{u}"
        body = [
            "acc: int64 = cast[int64](0)",
            "r: int64 = cast[int64](0)",
            "while r < reps:",
            "    v: int64 = cast[int64](1)",
            "    if r < thr:",
            "        i: int64 = cast[int64](0)",
            "        while i < inner:",
            "            v = v + r",
            "            i = i + cast[int64](1)",
            "    acc = acc + v",
            "    r = r + cast[int64](1)",
            "return acc",
        ]
        acc = 0
        for r in range(reps):
            v = 1
            if r < thr:
                for _i in range(inner):
                    v += r
            acc += v
        self._nl_emit_helper(
            fn, "reps: int64, inner: int64, thr: int64", body,
            f"cast[int64]({reps}), cast[int64]({inner}), cast[int64]({thr})", acc)

    # break/continue inside the inner loop, accumulator read after it.
    def _nl_break_continue(self, u):
        rng = self.rng
        reps = rng.randint(2, 5); inner = rng.randint(2, 8)
        brk = rng.randint(1, inner); skip = rng.randint(0, inner)
        fn = f"nl_bc_{u}"
        body = [
            "acc: int64 = cast[int64](0)",
            "r: int64 = cast[int64](0)",
            "while r < reps:",
            "    cnt: int64 = cast[int64](0)",
            "    i: int64 = cast[int64](0)",
            "    while i < inner:",
            "        i = i + cast[int64](1)",
            "        if i == skip:",
            "            continue",
            "        if i == brk:",
            "            break",
            "        cnt = cnt + cast[int64](1)",
            "    acc = acc + cnt",
            "    r = r + cast[int64](1)",
            "return acc",
        ]
        acc = 0
        for _r in range(reps):
            cnt = 0; i = 0
            while i < inner:
                i += 1
                if i == skip:
                    continue
                if i == brk:
                    break
                cnt += 1
            acc += cnt
        self._nl_emit_helper(
            fn, "reps: int64, inner: int64, brk: int64, skip: int64", body,
            f"cast[int64]({reps}), cast[int64]({inner}), "
            f"cast[int64]({brk}), cast[int64]({skip})", acc)

    # Early `return` out of nested loops.
    def _nl_early_return(self, u):
        rng = self.rng
        rows = rng.randint(2, 5); cols = rng.randint(2, 5)
        limit = rng.randint(1, rows * cols)
        fn = f"nl_er_{u}"
        body = [
            "s: int64 = cast[int64](0)",
            "a: int64 = cast[int64](0)",
            "while a < rr:",
            "    b: int64 = cast[int64](0)",
            "    while b < cc:",
            "        s = s + cast[int64](1)",
            "        if s >= lim:",
            "            return s",
            "        b = b + cast[int64](1)",
            "    a = a + cast[int64](1)",
            "return s",
        ]
        s = 0; done = False
        for _a in range(rows):
            for _b in range(cols):
                s += 1
                if s >= limit:
                    done = True
                    break
            if done:
                break
        self._nl_emit_helper(
            fn, "rr: int64, cc: int64, lim: int64", body,
            f"cast[int64]({rows}), cast[int64]({cols}), cast[int64]({limit})", s)

    # Accumulator mutated across three nesting levels, read at outer level.
    def _nl_cross_level(self, u):
        rng = self.rng
        o = rng.randint(2, 4); m = rng.randint(1, 4); n = rng.randint(1, 4)
        fn = f"nl_cl_{u}"
        body = [
            "acc: int64 = cast[int64](0)",
            "oi: int64 = cast[int64](0)",
            "while oi < oo:",
            "    tot: int64 = cast[int64](0)",
            "    mi: int64 = cast[int64](0)",
            "    while mi < mm:",
            "        ni: int64 = cast[int64](0)",
            "        while ni < nn:",
            "            tot = tot + cast[int64](1)",
            "            ni = ni + cast[int64](1)",
            "        tot = tot + mi",
            "        mi = mi + cast[int64](1)",
            "    acc = acc + tot",
            "    oi = oi + cast[int64](1)",
            "return acc",
        ]
        acc = 0
        for _o in range(o):
            tot = 0
            for mm_ in range(m):
                for _n in range(n):
                    tot += 1
                tot += mm_
            acc += tot
        self._nl_emit_helper(
            fn, "oo: int64, mm: int64, nn: int64", body,
            f"cast[int64]({o}), cast[int64]({m}), cast[int64]({n})", acc)


    # matmul-shaped loop-carried reduction. Targets the loop-carried register-
    # promotion levers directly:
    #   * The reduction update `s = s + p * q` and the IV update `acc = acc + s +
    #     k` name the carried scalar s/acc, and the inner index expression names
    #     the IVs k and n MULTIPLE times in ONE statement — the per-instruction
    #     use-vector DEDUP target (an under-counted use used to poison k/n for
    #     register promotion).
    #   * MULTIPLE simultaneously-live IVs (k, n, and the two strength-reduced
    #     index runs ka, kb) plus the carried accumulator s force register
    #     pressure so the spill-cost eviction policy is exercised.
    #   * A FRESH local `t` is redeclared EACH inner iteration and seeded from a
    #     DISTINCT value (s + k*n), threaded into s. If liveness wrongly coalesced
    #     t with another live value (or merged the redeclared t across iterations
    #     with a different carried value), the answer DIVERGES. Bit-exact vs the
    #     oracle proves the redeclared local was not wrongly coalesced.
    # Everything is simulated exactly in Python and folded into g_accum.
    def _nl_loopcarry(self, u):
        rng = self.rng
        rows = rng.randint(2, 5); cols = rng.randint(2, 6)
        c1 = rng.randint(1, 4); c2 = rng.randint(1, 3)
        fn = f"nl_lc_{u}"
        body = [
            "s: int64 = cast[int64](0)",
            "k: int64 = cast[int64](0)",
            "while k < rr:",
            "    ka: int64 = k * cc",
            "    n: int64 = cast[int64](0)",
            "    while n < cc:",
            # carried scalar s named twice; IVs k and n named twice in one stmt
            "        t: int64 = s + (k * n + ka)",
            "        t = t + (k * a1 + n * a2)",
            "        s = s + t",
            "        n = n + cast[int64](1)",
            "    k = k + cast[int64](1)",
            "return s",
        ]
        s = 0
        for k in range(rows):
            ka = I64.wrap(k * cols)
            for n in range(cols):
                t = I64.wrap(s + I64.wrap(k * n + ka))
                t = I64.wrap(t + I64.wrap(k * c1 + n * c2))
                s = I64.wrap(s + t)
        self._nl_emit_helper(
            fn, "rr: int64, cc: int64, a1: int64, a2: int64", body,
            f"cast[int64]({rows}), cast[int64]({cols}), "
            f"cast[int64]({c1}), cast[int64]({c2})", s)

    # ---- per-region caller-saved regalloc traffic (--opt P3-region) ----------
    #
    # Stresses the PER-REGION caller-saved register allocation (regalloc.ad:
    # ra_pool_cap_for / cfg.lr_spans_call). Before this lever, the caller-saved
    # extension pool {rdi,r8,r9,r10,r11} was unlocked ONLY in a WHOLE-FUNCTION
    # call-free function. Now a value whose LIVE RANGE spans no call may use a
    # caller-saved register EVEN inside a function that calls elsewhere — the
    # matmul accumulator confined to a call-free inner loop is the motivating case.
    #
    # CORRECTNESS CRUX — a value live ACROSS a call must NEVER be left in a
    # caller-saved register (the callee clobbers it => silent miscompile). Each
    # shape below is built so the by-construction oracle (Python shadow folded into
    # g_accum) is EXACT, so any wrong caller-saved promotion of a call-spanning
    # value DIVERGES under ADDER_OPT=1. The shapes:
    #
    #   (1) CALL-FREE HOT LOOP + CALL ELSEWHERE — a function whose hot inner loop
    #       (a reduction accumulator) is call-free, but which ALSO calls a helper
    #       BEFORE/AFTER the loop (so cfg_fn_has_call==1). The accumulator is
    #       caller-saved-ELIGIBLE; this is the lever's intended win. Correct iff the
    #       reduction value matches.
    #   (2) VALUE LIVE ACROSS A CALL — a local computed, then a helper call, then
    #       the local READ (and folded). It MUST stay callee-saved/spilled; if it
    #       lands in a caller-saved reg the helper clobbers it. The helper does real
    #       work (its own loop) so it genuinely writes rdi/r8-r11. THE CLOBBER
    #       CATCHER.
    #   (3) NESTED CALL-FREE LOOPS inside a call-bearing function — multiple
    #       loop-confined accumulators, with a call straddling the nest, so several
    #       values are caller-saved-eligible while values around the call are not.
    #   (4) VALUE LIVE-OUT OF A CALL-FREE LOOP INTO A CALL — a loop accumulator
    #       (call-free WHILE live in the loop) whose range EXTENDS past the loop to
    #       a point AT/AFTER a call that consumes it: lr_spans_call must see the
    #       call inside its (extended) range and keep it OFF the caller-saved pool.
    def _gen_region_callsplit_traffic(self, env):
        rng = self.rng
        if not hasattr(self, "_rc_uid"):
            self._rc_uid = 0
        # Emit the dedicated callee FIRST (once). It does real arithmetic work in
        # a loop so the compiled body genuinely writes the caller-saved registers
        # rdi/r8-r11 (argument marshalling + scratch), making any value wrongly
        # left in one across a call to it OBSERVABLY corrupt.
        if not hasattr(self, "_rc_callee_emitted"):
            self._rc_callee_emitted = True
            self.emit_top("def rc_work(x: int64, y: int64) -> int64:")
            self.emit_top("    w: int64 = x")
            self.emit_top("    j: int64 = cast[int64](0)")
            self.emit_top("    while j < cast[int64](4):")
            self.emit_top("        w = w + (x * cast[int64](3) + y)")
            self.emit_top("        w = w - y")
            self.emit_top("        j = j + cast[int64](1)")
            self.emit_top("    return w")
            self.emit_top("")

        def rc_work(x, y):
            w = x
            for _ in range(4):
                w = I64.wrap(w + I64.wrap(I64.wrap(x * 3) + y))
                w = I64.wrap(w - y)
            return w

        for _ in range(rng.randint(2, 4)):
            shape = rng.choice([
                "callfree_loop_plus_call",   # (1)
                "live_across_call",          # (2) clobber catcher
                "nested_callfree_plus_call", # (3)
                "loopval_liveout_to_call",   # (4)
            ])
            self._rc_uid += 1
            u = self._rc_uid
            if shape == "callfree_loop_plus_call":
                self._rc_callfree_loop_plus_call(u, rc_work)
            elif shape == "live_across_call":
                self._rc_live_across_call(u, rc_work)
            elif shape == "nested_callfree_plus_call":
                self._rc_nested_callfree(u, rc_work)
            else:
                self._rc_loopval_liveout(u, rc_work)

    # (1) Call-free hot loop accumulator + a call elsewhere in the same function.
    def _rc_callfree_loop_plus_call(self, u, rc_work):
        rng = self.rng
        n = rng.randint(3, 9); a = rng.randint(1, 5); b = rng.randint(1, 5)
        p = rng.randint(0, 7); q = rng.randint(0, 7)
        fn = f"rc_clp_{u}"
        body = [
            # call BEFORE the loop; pre is NOT read after the loop, so it does not
            # span the loop (its own short range may use caller-saved safely).
            "pre: int64 = rc_work(cast[int64](pp), cast[int64](qq))",
            # call-free hot loop: s (accumulator) and k (IV) are call-free for
            # their whole life -> caller-saved-ELIGIBLE.
            "s: int64 = pre",
            "k: int64 = cast[int64](0)",
            "while k < nn:",
            "    s = s + (k * aa + bb)",
            "    k = k + cast[int64](1)",
            "return s",
        ]
        pre = rc_work(I64.wrap(p), I64.wrap(q))
        s = pre
        for k in range(n):
            s = I64.wrap(s + I64.wrap(I64.wrap(k * a) + b))
        self._nl_emit_helper(
            fn, "nn: int64, aa: int64, bb: int64, pp: int64, qq: int64", body,
            f"cast[int64]({n}), cast[int64]({a}), cast[int64]({b}), "
            f"cast[int64]({p}), cast[int64]({q})", s)

    # (2) THE CLOBBER CATCHER: a value computed, a call, then the value read.
    # `keep` is live ACROSS the rc_work call -> MUST NOT be caller-saved.
    def _rc_live_across_call(self, u, rc_work):
        rng = self.rng
        a = rng.randint(2, 9); b = rng.randint(1, 9)
        p = rng.randint(0, 9); q = rng.randint(0, 9)
        fn = f"rc_lac_{u}"
        body = [
            # keep is defined BEFORE the call and read AFTER it -> spans the call.
            "keep: int64 = aa * bb + cast[int64](7)",
            # also a SECOND value spanning the call, to stress >1 callee-saved hold.
            "keep2: int64 = aa - bb",
            "mid: int64 = rc_work(cast[int64](pp), cast[int64](qq))",
            # both keep and keep2 read AFTER the call; if either was clobbered by
            # rc_work's caller-saved writes the fold diverges.
            "out: int64 = keep + mid + keep2",
            "return out",
        ]
        keep = I64.wrap(I64.wrap(a * b) + 7)
        keep2 = I64.wrap(a - b)
        mid = rc_work(I64.wrap(p), I64.wrap(q))
        out = I64.wrap(I64.wrap(keep + mid) + keep2)
        self._nl_emit_helper(
            fn, "aa: int64, bb: int64, pp: int64, qq: int64", body,
            f"cast[int64]({a}), cast[int64]({b}), "
            f"cast[int64]({p}), cast[int64]({q})", out)

    # (3) Nested call-free loops inside a call-bearing function. Inner/outer
    # accumulators are loop-confined (caller-saved-eligible); a call sits between
    # the nest and the final read.
    def _rc_nested_callfree(self, u, rc_work):
        rng = self.rng
        rows = rng.randint(2, 5); cols = rng.randint(2, 5)
        a = rng.randint(1, 4); p = rng.randint(0, 6); q = rng.randint(0, 6)
        fn = f"rc_ncf_{u}"
        body = [
            "s: int64 = cast[int64](0)",
            "i: int64 = cast[int64](0)",
            "while i < rr:",
            "    j: int64 = cast[int64](0)",
            "    while j < cc:",
            "        s = s + (i * cc + j) * aa",
            "        j = j + cast[int64](1)",
            "    i = i + cast[int64](1)",
            # call AFTER the nest; tail is live across it -> callee-saved/spilled.
            "tail: int64 = rc_work(cast[int64](pp), cast[int64](qq))",
            "return s + tail",
        ]
        s = 0
        for i in range(rows):
            for j in range(cols):
                s = I64.wrap(s + I64.wrap(I64.wrap(i * cols + j) * a))
        tail = rc_work(I64.wrap(p), I64.wrap(q))
        res = I64.wrap(s + tail)
        self._nl_emit_helper(
            fn, "rr: int64, cc: int64, aa: int64, pp: int64, qq: int64", body,
            f"cast[int64]({rows}), cast[int64]({cols}), cast[int64]({a}), "
            f"cast[int64]({p}), cast[int64]({q})", res)

    # (4) A loop accumulator that is live-OUT of a call-free loop INTO a call: its
    # range extends to a point at/after a call, so lr_spans_call must keep it off
    # the caller-saved pool even though the loop body itself is call-free.
    def _rc_loopval_liveout(self, u, rc_work):
        rng = self.rng
        n = rng.randint(3, 8); a = rng.randint(1, 5)
        q = rng.randint(0, 7)
        fn = f"rc_lvo_{u}"
        body = [
            "acc: int64 = cast[int64](0)",
            "k: int64 = cast[int64](0)",
            "while k < nn:",
            "    acc = acc + (k * aa + cast[int64](1))",
            "    k = k + cast[int64](1)",
            # acc is used as an ARGUMENT to the call: it is live AT the call point,
            # so its range spans the call -> must not be caller-saved.
            "z: int64 = rc_work(acc, cast[int64](qq))",
            "return acc + z",
        ]
        acc = 0
        for k in range(n):
            acc = I64.wrap(acc + I64.wrap(I64.wrap(k * a) + 1))
        z = rc_work(I64.wrap(acc), I64.wrap(q))
        res = I64.wrap(acc + z)
        self._nl_emit_helper(
            fn, "nn: int64, aa: int64, qq: int64", body,
            f"cast[int64]({n}), cast[int64]({a}), cast[int64]({q})", res)

    # ---- short-circuit logical and/or traffic --------------------------------
    def _gen_short_circuit_traffic(self, env):
        """Emit logical `and`/`or` expressions whose RIGHT operand has an
        observable SIDE EFFECT (sc_bump bumps g_sc), so the differential proves
        the backend SHORT-CIRCUITS (Python/Adder semantics) — i.e. does NOT
        evaluate the RHS when the LHS already decides the result. The earlier
        codegen.ad bitwise-fold lowering evaluated BOTH operands and would
        over-bump g_sc; the seed (gen_short_circuit) does not. We fold both the
        boolean result AND the resulting g_sc into g_accum, so a non-short-
        circuit regression diverges from the oracle. Both subset and default
        mode emit byte-identically (same rng stream)."""
        rng = self.rng
        sc = 0  # oracle shadow of g_sc
        for _ in range(rng.randint(4, 8)):
            op = rng.choice(["and", "or"])
            # LHS is a compile-time-known truthiness so the oracle knows whether
            # the RHS runs; we encode it as `(L != 0)` over a literal L.
            lhs_true = rng.randint(0, 1)
            lhs = 1 if lhs_true else 0
            rhs_true = rng.randint(0, 1)
            rret = 1 if rhs_true else 0
            # Whether the RHS (sc_bump) is evaluated under short-circuit rules:
            #   and: RHS runs iff LHS is truthy
            #   or : RHS runs iff LHS is falsy
            rhs_runs = (lhs_true == 1) if op == "and" else (lhs_true == 0)
            if rhs_runs:
                sc += 1
            # result value (0/1) under short-circuit semantics
            if op == "and":
                res = 1 if (lhs_true and rhs_true) else 0
            else:
                res = 1 if (lhs_true or rhs_true) else 0
            # Emit: `b = (L != 0) <op> (sc_bump(R) != 0)` — the RHS deref/call
            # only fires under correct short-circuiting.
            self.emit(
                f"    scb: int64 = cast[int64](0)")
            self.emit(
                f"    if (cast[int64]({lhs}) != cast[int64](0)) {op} "
                f"(sc_bump(cast[int64]({rret})) != cast[int64](0)):")
            self.emit(f"        scb = cast[int64](1)")
            self._fold_value("cast[uint64](scb)", U64.wrap(res))
        # Fold the OBSERVED side-effect count: this is the load-bearing check —
        # it only matches the oracle if the backend short-circuited exactly.
        self._fold_value("g_sc", U64.wrap(sc))

    # ---- helper-call traffic -------------------------------------------------
    def _gen_helper_calls(self, env):
        rng = self.rng
        for (name, pyfn, nargs) in self.helpers:
            for _ in range(rng.randint(1, 3)):
                argvals = [rng.randint(-1000, 1000) for _ in range(nargs)]
                argsrc = ", ".join(
                    (f"cast[int64](0 - {(-v)})" if v < 0
                     else f"cast[int64]({v})") for v in argvals)
                res = pyfn([I64.wrap(v) for v in argvals])
                self.emit(f"    hc: int64 = {name}({argsrc})")
                self._fold_value("cast[uint64](hc)", U64.wrap(res))

    # ---- register-pressure / caller-saved-scratch traffic --------------------
    def _gen_regpressure_scratch_traffic(self, env):
        """Stress the --opt register-to-register binop lowering, specifically the
        CALLER-SAVED IR scratch extension (codegen.ad: ir_scratch caller-saved
        pool, indices 5..9 = rdi/r8/r9/r10/r11). That pool is used ONLY across a
        CALL-FREE IR tree when the callee-saved scratch pool is exhausted (deep
        nesting and/or regalloc consuming all 5 callee-saved registers). main()
        ALWAYS makes calls (print_u64), so regalloc gets NO caller-saved pool
        here; the caller-saved scratch must therefore come from the per-TREE
        call-free gate — exactly the path this traffic exercises.

        Three shapes, all folded into g_accum by construction so the differential
        oracle (Python seed vs codegen.ad --opt) catches any miscompile:

          (1) DEEP CALL-FREE BINOP TREES over many distinct int64 locals — a
              balanced expression whose simultaneous scratch demand exceeds the 5
              callee-saved registers, forcing caller-saved scratch. Value is
              computed in the EXACT 64-bit two's-complement model and folded.
          (2) REGISTER-PRESSURE under regalloc — the same trees referencing 6-10
              live locals so the callee-saved pool is busy with promoted locals
              and the scratch must spill to caller-saved.
          (3) EVAL-ORDER / CLOBBER soundness — a binop whose operands are
              side-effecting calls (sc_ord appends an id to g_ord). The seed
              evaluates RIGHT before LEFT; the register lowering parks RIGHT in a
              scratch reg across LEFT, so g_ord MUST record the identical order.
              A function call mid-expression (one operand IS a call) ALSO forces
              the tree NON-call-free, so the caller-saved gate must REFUSE it and
              fall back — the differential proves both the used and the refused
              path stay correct.
        """
        rng = self.rng
        M = (1 << 64) - 1

        def w64(v):
            """Wrap to int64 (signed two's complement) — the register model."""
            v &= M
            if v >> 63:
                v -= (1 << 64)
            return v

        # Eval-ORDER observer, emitted as PROGRAM top-level (NOT the shared
        # PRELUDE, so the regpressure/isel corpora — which paste PRELUDE before a
        # hand-written main and assert a push-free image — are unaffected). Each
        # sc_ord call appends its decimal id to g_ord (g_ord = g_ord*10 + id) and
        # returns `ret`, so the recorded order observes a binop's operand
        # evaluation order. Emitted in BOTH subset and default mode.
        self.emit_top("g_ord: uint64")
        self.emit_top("")
        self.emit_top("def sc_ord(id: int64, ret: int64) -> int64:")
        self.emit_top("    g_ord = g_ord * cast[uint64](10) + cast[uint64](id)")
        self.emit_top("    return ret")
        self.emit_top("")

        # ----- (1)+(2) deep call-free trees over many distinct locals ----------
        # Declare 10 fresh locals with known values, then build several deep
        # nested binop trees referencing them. 10 distinct simultaneously-live
        # operands guarantee the scratch demand exceeds 5 callee-saved regs.
        nvars = 10
        vals = [w64(rng.randint(-(1 << 40), (1 << 40))) for _ in range(nvars)]
        for i in range(nvars):
            v = vals[i]
            src = f"cast[int64](0 - {(-v)})" if v < 0 else f"cast[int64]({v})"
            self.emit(f"    rp{i}: int64 = {src}")

        def leaf(i):
            return (f"rp{i}", vals[i])

        def build_tree(depth):
            """Random deep binop tree over the rp locals; returns (src, value)."""
            if depth <= 0:
                return leaf(rng.randrange(nvars))
            op = rng.choice(["+", "-", "*", "&", "|", "^"])
            ls, lv = build_tree(depth - 1)
            rs, rv = build_tree(depth - 1)
            if op == "+":
                rv2 = lv + rv
            elif op == "-":
                rv2 = lv - rv
            elif op == "*":
                rv2 = lv * rv
            elif op == "&":
                rv2 = lv & rv
            elif op == "|":
                rv2 = lv | rv
            else:
                rv2 = lv ^ rv
            return (f"({ls} {op} {rs})", w64(rv2))

        for _ in range(rng.randint(3, 5)):
            # depth 4 => up to 16 leaves, deeply nested: peak scratch demand
            # comfortably exceeds 5, exercising caller-saved scratch acquisition.
            s, val = build_tree(4)
            self.emit(f"    rpt: int64 = {s}")
            self._fold_value("cast[uint64](rpt)", U64.wrap(w64(val)))

        # A compare tree feeding a branch (compares also use the scratch pool):
        s1, v1 = build_tree(3)
        s2, v2 = build_tree(3)
        cmpres = 1 if w64(v1) < w64(v2) else 0
        self.emit(f"    rpc: int64 = cast[int64](0)")
        self.emit(f"    if ({s1}) < ({s2}):")
        self.emit(f"        rpc = cast[int64](1)")
        self._fold_value("cast[uint64](rpc)", U64.wrap(cmpres))

        # ----- (3) eval-order + mid-expression call (clobber) soundness --------
        # `sc_ord(L, lval) OP sc_ord(R, rval)` : the seed evaluates the RIGHT
        # operand FIRST (id R appended to g_ord), then the LEFT (id L). The
        # register lowering parks RIGHT in a scratch across LEFT — the recorded
        # order MUST be identical. Each call makes the tree NON-call-free, so the
        # caller-saved gate refuses it; this asserts the FALLBACK path is correct
        # AND that operand order is preserved.
        g_ord_shadow = 0
        for _ in range(rng.randint(3, 6)):
            lid = rng.randint(1, 9)
            rid = rng.randint(1, 9)
            lval = w64(rng.randint(-1000, 1000))
            rval = w64(rng.randint(-1000, 1000))
            op = rng.choice(["+", "-", "*", "&", "|", "^"])
            lsrc = f"cast[int64](0 - {(-lval)})" if lval < 0 else f"cast[int64]({lval})"
            rsrc = f"cast[int64](0 - {(-rval)})" if rval < 0 else f"cast[int64]({rval})"
            # SEED EVAL ORDER: right then left.
            g_ord_shadow = g_ord_shadow * 10 + rid
            g_ord_shadow = g_ord_shadow * 10 + lid
            g_ord_shadow &= M
            if op == "+":
                rv = lval + rval
            elif op == "-":
                rv = lval - rval
            elif op == "*":
                rv = lval * rval
            elif op == "&":
                rv = lval & rval
            elif op == "|":
                rv = lval | rval
            else:
                rv = lval ^ rval
            self.emit(
                f"    rpo: int64 = (sc_ord(cast[int64]({lid}), {lsrc}) "
                f"{op} sc_ord(cast[int64]({rid}), {rsrc}))")
            self._fold_value("cast[uint64](rpo)", U64.wrap(w64(rv)))
        # Fold the observed evaluation order — the load-bearing eval-order check.
        self._fold_value("g_ord", U64.wrap(g_ord_shadow))

    # ---- fold one known value into the printed accumulator -------------------
    def _fold_value(self, src_u64, py_u64):
        self.emit(f"    g_accum = g_accum + ({src_u64})")
        self._acc_add(py_u64)

    # ======================================================================
    # Track-3 self-hosting parity constructs: structs, classes/methods,
    # for-loops (range + array), do-while. Each is generated in BOTH subset
    # and default mode (byte-identical rng stream) and folded into g_accum so
    # the by-construction oracle has exact ground truth.
    # ======================================================================

    # ---- struct definition: `Pt` with one scalar field per store width -------
    def _build_struct_def(self):
        rng = self.rng
        # A fixed field set (one per store width) keeps the layout
        # deterministic; field VALUES are random and shadowed at runtime.
        self.struct_fields = list(STORE_TYPES)
        self.struct_shadow = {}                 # field name -> stored value
        self.emit_top("class Pt:")
        for t in self.struct_fields:
            fname = f"f_{t.name}"
            self.emit_top(f"    {fname}: {t.name}")
            self.struct_shadow[fname] = 0
        self.emit_top("")

    # ---- struct local: member stores + reads ---------------------------------
    def _gen_struct_traffic(self, env):
        rng = self.rng
        # `Pt` has no __init__, so declare a bare (zeroed) struct local; every
        # field is explicitly stored below before being read.
        self.emit("    pt: Pt")
        # Member STORE: pt.f_T = <typed expr>; sized store truncates to T.
        for t in self.struct_fields:
            fname = f"f_{t.name}"
            g = Gen(rng, env)
            e = g._expr_typed(2, t)
            self.emit(f"    pt.{fname} = {e.src}")
            self.struct_shadow[fname] = t.wrap(e.val)
        # Augmented member store on one field: pt.f_T += <typed expr>.
        # The field load widens via the field's signedness, the add is 64-bit,
        # and the sized store truncates back to T.
        for _ in range(rng.randint(1, 2)):
            t = rng.choice(self.struct_fields)
            fname = f"f_{t.name}"
            g = Gen(rng, env)
            e = g._expr_typed(2, t)
            self.emit(f"    pt.{fname} = pt.{fname} + ({e.src})")
            old_reg = _to_reg(t.wrap(self.struct_shadow[fname]))  # field reload widens
            new = t.wrap(old_reg + e.reg)
            self.struct_shadow[fname] = new
        # Member READ: fold each field widened to uint64 via its signedness.
        for t in self.struct_fields:
            fname = f"f_{t.name}"
            stored = self.struct_shadow[fname]
            self._fold_value(
                f"cast[uint64](cast[{t.name}](pt.{fname}))",
                U64.wrap(stored))
            # SIGN-FAITHFUL member read (no inner cast[T]): the MEMBER LOAD
            # itself must sign-extend a signed sub-8-byte field / zero-extend an
            # unsigned one. The inner cast[T] above re-extends and MASKS a wrong
            # member-load extension (a signed int8 field of -1 reads the same
            # low byte whether the load zero- or sign-extended); this fold
            # observes the load's own extension. stored is the field's type-view
            # value (negative for a signed field); _to_reg widens it into the
            # 64-bit register exactly as a correct sign/zero-extending member
            # load would. This is the path that previously zero-extended a
            # signed field in BOTH backends and so escaped the differential.
            self._fold_value(
                f"cast[uint64](pt.{fname})",
                U64.wrap(_to_reg(stored)))

    # ---- class definition: fields + __init__ + a method ----------------------
    def _build_class_def(self):
        rng = self.rng
        # `Counter` holds two int64 fields set by __init__ and a method that
        # returns an int64 derived from the fields and an argument. All int64
        # so the oracle is a straight signed-64 model.
        self.emit_top("class Counter:")
        self.emit_top("    a: int64")
        self.emit_top("    b: int64")
        # __init__(self, ia, ib): a = ia; b = ib
        self.emit_top("    def __init__(self, ia: int64, ib: int64):")
        self.emit_top("        self.a = ia")
        self.emit_top("        self.b = ib")
        # combine(self, x): r = a * x + b ; return r
        self.emit_top("    def combine(self, x: int64) -> int64:")
        self.emit_top("        r: int64 = self.a * x + self.b")
        self.emit_top("        return r")
        self.emit_top("")

    # ---- multi-base class: method inherited from a NON-FIRST base ------------
    # Track-3 multi-base receiver-offset parity. `MBase0` and `MBase1` each
    # carry two int64 fields + a method; `MDerived(MBase0, MBase1)` flattens
    # MBase0 (offset 0) then MBase1 (offset 16) then its own field. Calling
    # `mfirst` (declared in MBase0) needs NO receiver bump; calling `msecond`
    # (declared in MBase1, the SECOND base) requires the codegen to bump the
    # receiver pointer by sizeof(MBase0)=16 so `self.field` lands on MBase1's
    # bytes. A backend that omits the bump reads MBase0's fields instead, so
    # the oracle (which models the correct fields) catches it. All int64 ->
    # straight signed-64 oracle.
    def _build_multibase_def(self):
        self.emit_top("class MBase0:")
        self.emit_top("    p: int64")
        self.emit_top("    q: int64")
        self.emit_top("    def mfirst(self, x: int64) -> int64:")
        self.emit_top("        return self.p * x + self.q")
        self.emit_top("")
        self.emit_top("class MBase1:")
        self.emit_top("    u: int64")
        self.emit_top("    v: int64")
        self.emit_top("    def msecond(self, x: int64) -> int64:")
        self.emit_top("        return self.u - x + self.v")
        self.emit_top("")
        self.emit_top("class MDerived(MBase0, MBase1):")
        self.emit_top("    w: int64")
        self.emit_top("")

    def _gen_class_traffic(self, env):
        rng = self.rng
        ia = rng.randint(-1000, 1000)
        ib = rng.randint(-1000, 1000)
        x = rng.randint(-50, 50)
        ia_s = f"cast[int64](0 - {(-ia)})" if ia < 0 else f"cast[int64]({ia})"
        ib_s = f"cast[int64](0 - {(-ib)})" if ib < 0 else f"cast[int64]({ib})"
        x_s = f"cast[int64](0 - {(-x)})" if x < 0 else f"cast[int64]({x})"
        self.emit(f"    ctr: Counter = Counter({ia_s}, {ib_s})")
        # Read the fields back (member load), fold each.
        self._fold_value("cast[uint64](ctr.a)", U64.wrap(I64.wrap(ia)))
        self._fold_value("cast[uint64](ctr.b)", U64.wrap(I64.wrap(ib)))
        # Method dispatch: r = a*x + b.
        r = I64.wrap(I64.wrap(I64.wrap(ia) * I64.wrap(x)) + I64.wrap(ib))
        self.emit(f"    cr: int64 = ctr.combine({x_s})")
        self._fold_value("cast[uint64](cr)", U64.wrap(r))

    # ---- multi-base traffic: inherited method from a non-first base ----------
    def _gen_multibase_traffic(self, env):
        rng = self.rng
        # Bare (zeroed) MDerived local; store all five flattened fields, then
        # dispatch mfirst (MBase0, offset 0) and msecond (MBase1, offset 16).
        pv = rng.randint(-1000, 1000)
        qv = rng.randint(-1000, 1000)
        uv = rng.randint(-1000, 1000)
        vv = rng.randint(-1000, 1000)
        wv = rng.randint(-1000, 1000)
        xf = rng.randint(-50, 50)
        xs = rng.randint(-50, 50)
        def cs(n):
            return f"cast[int64](0 - {(-n)})" if n < 0 else f"cast[int64]({n})"
        self.emit("    md: MDerived")
        self.emit(f"    md.p = {cs(pv)}")
        self.emit(f"    md.q = {cs(qv)}")
        self.emit(f"    md.u = {cs(uv)}")
        self.emit(f"    md.v = {cs(vv)}")
        self.emit(f"    md.w = {cs(wv)}")
        # Read every field back (member load), folding each.
        self._fold_value("cast[uint64](md.p)", U64.wrap(I64.wrap(pv)))
        self._fold_value("cast[uint64](md.q)", U64.wrap(I64.wrap(qv)))
        self._fold_value("cast[uint64](md.u)", U64.wrap(I64.wrap(uv)))
        self._fold_value("cast[uint64](md.v)", U64.wrap(I64.wrap(vv)))
        self._fold_value("cast[uint64](md.w)", U64.wrap(I64.wrap(wv)))
        # mfirst (MBase0, receiver_offset 0): p*x + q.
        rf = I64.wrap(I64.wrap(I64.wrap(pv) * I64.wrap(xf)) + I64.wrap(qv))
        self.emit(f"    mrf: int64 = md.mfirst({cs(xf)})")
        self._fold_value("cast[uint64](mrf)", U64.wrap(rf))
        # msecond (MBase1, receiver_offset 16): u - x + v. A missing bump
        # would read p,q instead of u,v and diverge here.
        rsv = I64.wrap(I64.wrap(I64.wrap(uv) - I64.wrap(xs)) + I64.wrap(vv))
        self.emit(f"    mrs: int64 = md.msecond({cs(xs)})")
        self._fold_value("cast[uint64](mrs)", U64.wrap(rsv))

    # ---- for v in range(...) : integer counter loop --------------------------
    def _gen_for_range_traffic(self, env):
        rng = self.rng
        # Ascending range(start, stop) with a body that sums i (and conditions
        # on i) into a uint64 accumulator. continue/break exercised lightly.
        start = rng.randint(0, 5)
        stop = start + rng.randint(3, 12)
        thr = rng.randint(start, stop)
        self.emit("    fr_sum: uint64 = cast[uint64](0)")
        self.emit(f"    for fi in range(cast[int64]({start}), cast[int64]({stop})):")
        self.emit(f"        if fi < cast[int64]({thr}):")
        self.emit("            fr_sum = fr_sum + cast[uint64](fi)")
        self.emit("        else:")
        self.emit("            fr_sum = fr_sum + cast[uint64](fi * cast[int64](2))")
        py = 0
        for fi in range(start, stop):
            py += fi if fi < thr else I64.wrap(fi * 2)
            py &= umask(64)
        self._fold_value("fr_sum", py)

        # A range(stop) one-arg form with a `continue` (skip even i) + break.
        n = rng.randint(4, 10)
        brk = rng.randint(n, n + 3)        # may not trigger (>=n) -> full loop
        self.emit("    fr2: uint64 = cast[uint64](0)")
        self.emit(f"    for fj in range(cast[int64]({n})):")
        self.emit(f"        if fj >= cast[int64]({brk}):")
        self.emit("            break")
        self.emit("        fr2 = fr2 + cast[uint64](fj)")
        py2 = 0
        for fj in range(n):
            if fj >= brk:
                break
            py2 = (py2 + fj) & umask(64)
        self._fold_value("fr2", py2)

    # ---- for v in <array global> : element iteration -------------------------
    def _gen_for_array_traffic(self, env):
        rng = self.rng
        # Iterate one of the per-width store arrays (already populated by
        # _gen_store_traffic) and sum the elements, widened per the element
        # type's signedness. The loop var is a private copy of the element.
        t = rng.choice(STORE_TYPES)
        name, n, shadow = self.store_arrays[t]
        self.emit("    fa_sum: uint64 = cast[uint64](0)")
        self.emit(f"    for fe in {name}:")
        self.emit(f"        fa_sum = fa_sum + cast[uint64](cast[{t.name}](fe))")
        py = 0
        for v in shadow:
            py = (py + U64.wrap(t.wrap(v))) & umask(64)
        self._fold_value("fa_sum", py)

    # ---- do { body } while (cond) --------------------------------------------
    def _gen_do_while_traffic(self, env):
        rng = self.rng
        # A do-while that runs at least once; body sums a counter, condition
        # gates the next iteration. `continue` exercised via an if.
        n = rng.randint(1, 8)
        self.emit("    dw_i: int64 = 0")
        self.emit("    dw_sum: uint64 = cast[uint64](0)")
        self.emit("    do:")
        self.emit("        dw_sum = dw_sum + cast[uint64](dw_i)")
        self.emit("        dw_i = dw_i + 1")
        self.emit(f"    while dw_i < cast[int64]({n})")
        py = 0
        dw_i = 0
        while True:
            py = (py + dw_i) & umask(64)
            dw_i += 1
            if not (dw_i < n):
                break
        self._fold_value("dw_sum", py)

    # ======================================================================
    # CMP+JCC branch-condition traffic (--opt cmp; jcc lever). A comparison
    # that feeds a conditional branch (if/while/for/do-while condition, and the
    # short-circuit &&/|| edges) is lowered to a direct `cmp; jcc` instead of
    # materializing a 0/1 boolean and re-testing it. The CRUX bug class is the
    # signed-vs-unsigned jcc (jb vs jl) and the branch-sense negation: a wrong
    # jcc silently takes the wrong arm. This generator hammers it with:
    #   * every comparison op (== != < <= > >=) as an if/while condition,
    #   * SIGNED and UNSIGNED operands, including values that DIFFER in outcome
    #     under signed vs unsigned interpretation (e.g. 0xFFFFFFFFFFFFFFFF which
    #     is -1 signed but the maximum unsigned — `x < 0` signed is the inverse
    #     of `x < 0` unsigned),
    #   * branch-if-TRUE (the body runs) and branch-if-FALSE (an else / skip),
    #   * negated conditions `if not (a < b):`,
    #   * short-circuit `&&` / `||` chains of comparisons (internal edges become
    #     cmp; jcc; the chain's own boolean VALUE is still materialized),
    #   * comparisons whose boolean VALUE is ALSO used (assigned to a local and
    #     folded) — these must STILL materialize correctly (the value-use case
    #     the lever must NOT touch).
    # Each construct's observable effect is shadowed in Python and folded into
    # g_accum, so any wrong branch / wrong jcc diverges the differential oracle.
    # Emitted in BOTH modes with an identical rng stream.
    # ======================================================================
    def _cmpjcc_eval(self, op, x, y, signed):
        """Python truth value of `x op y` under signed/unsigned 64-bit semantics,
        mirroring the backend's _rel_cc choice (eq/ne are bit-compares)."""
        xr = x & umask(64)
        yr = y & umask(64)
        if op == "==":
            return xr == yr
        if op == "!=":
            return xr != yr
        if signed:
            xv, yv = _signed64(xr), _signed64(yr)
        else:
            xv, yv = xr, yr
        return {"<": xv < yv, "<=": xv <= yv, ">": xv > yv, ">=": xv >= yv}[op]

    def _gen_cmpjcc_traffic(self, env):
        rng = self.rng
        OPS = ["<", "<=", ">", ">=", "==", "!="]
        # Operand pairs that EXPOSE the signed-vs-unsigned distinction: the same
        # bit pattern compares differently as signed vs unsigned. The first few
        # are the classic miscompile trap (-1 vs 1: signed -1 < 1 but unsigned
        # 0xFFF... > 1) — the jb-vs-jl divergence.
        TRAP_PAIRS = [
            (0xFFFFFFFFFFFFFFFF, 1),                 # -1 vs 1
            (0x8000000000000000, 1),                 # INT64_MIN vs 1
            (0x7FFFFFFFFFFFFFFF, 0x8000000000000000),# INT64_MAX vs INT64_MIN
            (0xFFFFFFFFFFFFFFFF, 0),                 # -1 vs 0
            (0, 0xFFFFFFFFFFFFFFFF),                 # 0 vs -1
            (5, 5),                                  # equal
            (3, 9),                                  # small ordered
        ]
        # A FIXED, SMALL set of reusable locals (declared ONCE) keeps this whole
        # generator under the backend's MAX_LOCALS budget no matter how many
        # cases the per-program budget draws — the operands/result are re-ASSIGNED
        # per case, not re-declared. Two operand slots per signedness + one
        # result slot. The `while`/`do`/`for` counters get their own reused slots.
        self.emit("    cj_si: int64 = 0")
        self.emit("    cj_sj: int64 = 0")
        self.emit("    cj_ui: uint64 = cast[uint64](0)")
        self.emit("    cj_uj: uint64 = cast[uint64](0)")
        self.emit("    cj_r:  uint64 = cast[uint64](0)")
        self.emit("    cj_ctr: int64 = 0")
        self.emit("    cj_sum: uint64 = cast[uint64](0)")

        def operands(signed):
            return ("cj_si", "cj_sj") if signed else ("cj_ui", "cj_uj")

        def load(signed, xv, yv):
            ty = "int64" if signed else "uint64"
            xn, yn = operands(signed)
            self.emit(f"    {xn} = cast[{ty}]({xv})")
            self.emit(f"    {yn} = cast[{ty}]({yv})")
            return xn, yn

        # Per-program budget: draw a handful of cases for each shape so coverage
        # accumulates across the 700-seed corpus while each program stays small.
        # ---- (1) if/else branch-if-true over a comparison, both signednesses.
        for _ in range(rng.randint(2, 4)):
            op = rng.choice(OPS)
            signed = rng.random() < 0.5
            xv, yv = rng.choice(TRAP_PAIRS)
            xn, yn = load(signed, xv, yv)
            self.emit(f"    if {xn} {op} {yn}:")
            self.emit(f"        cj_r = cast[uint64](7)")
            self.emit(f"    else:")
            self.emit(f"        cj_r = cast[uint64](11)")
            self._fold_value("cj_r", 7 if self._cmpjcc_eval(op, xv, yv, signed) else 11)

        # ---- (2) NEGATED condition `if not (a op b):` — branch-sense flip ------
        for _ in range(rng.randint(1, 3)):
            op = rng.choice(OPS)
            signed = rng.random() < 0.5
            xv, yv = rng.choice(TRAP_PAIRS)
            xn, yn = load(signed, xv, yv)
            self.emit(f"    if not ({xn} {op} {yn}):")
            self.emit(f"        cj_r = cast[uint64](13)")
            self.emit(f"    else:")
            self.emit(f"        cj_r = cast[uint64](17)")
            res = 13 if (not self._cmpjcc_eval(op, xv, yv, signed)) else 17
            self._fold_value("cj_r", res)

        # ---- (3) while loop driven by a comparison condition (cmp; jcc exit) ---
        for _ in range(rng.randint(1, 2)):
            op = rng.choice(("<", "<=", "!="))
            n = rng.randint(1, 9)
            self.emit("    cj_ctr = 0")
            self.emit("    cj_sum = cast[uint64](0)")
            self.emit(f"    while cj_ctr {op} cast[int64]({n}):")
            self.emit("        cj_sum = cj_sum + cast[uint64](cj_ctr)")
            self.emit("        cj_ctr = cj_ctr + 1")
            py = 0
            iv = 0
            # Guard against a degenerate infinite loop in the oracle (e.g. != with
            # a count it skips past): cap iterations identically to the compiled
            # ascending counter, which only ever runs while the condition holds.
            while self._cmpjcc_eval(op, iv, n, True) and iv <= n + 2:
                py = (py + iv) & umask(64)
                iv += 1
            self._fold_value("cj_sum", py)

        # ---- (4) for-range loop (its < lowers to cmp; jge exit) ----------------
        n = rng.randint(2, 10)
        self.emit("    cj_sum = cast[uint64](0)")
        self.emit(f"    for cj_fi in range({n}):")
        self.emit("        cj_sum = cj_sum + cast[uint64](cj_fi)")
        self._fold_value("cj_sum", (sum(range(n))) & umask(64))

        # ---- (5) do-while with a comparison back-edge (cmp; jcc start) ---------
        m = rng.randint(1, 7)
        self.emit("    cj_ctr = 0")
        self.emit("    cj_sum = cast[uint64](0)")
        self.emit("    do:")
        self.emit("        cj_sum = cj_sum + cast[uint64](cj_ctr)")
        self.emit("        cj_ctr = cj_ctr + 1")
        self.emit(f"    while cj_ctr <= cast[int64]({m})")
        py = 0
        dv = 0
        while True:
            py = (py + dv) & umask(64)
            dv += 1
            if not (dv <= m):
                break
        self._fold_value("cj_sum", py)

        # ---- (6) short-circuit &&/|| chains of comparisons feeding a branch ----
        #      Internal edges become cmp; jcc; the chain's boolean VALUE is still
        #      materialized (used by the `if`, and ALSO assigned to a local).
        for _ in range(rng.randint(1, 3)):
            conn = rng.choice(("and", "or"))
            signed = rng.random() < 0.5
            ty = "int64" if signed else "uint64"
            ax, ay = rng.choice(TRAP_PAIRS)
            bx, by = rng.choice(TRAP_PAIRS)
            op1, op2 = rng.choice(OPS), rng.choice(OPS)
            # Use literal operands inline so no extra locals are consumed.
            la = f"cast[{ty}]({ax})"
            lb = f"cast[{ty}]({ay})"
            lc = f"cast[{ty}]({bx})"
            ld = f"cast[{ty}]({by})"
            cond = f"({la} {op1} {lb}) {conn} ({lc} {op2} {ld})"
            t1 = self._cmpjcc_eval(op1, ax, ay, signed)
            t2 = self._cmpjcc_eval(op2, bx, by, signed)
            chain = (t1 and t2) if conn == "and" else (t1 or t2)
            self.emit(f"    if {cond}:")
            self.emit(f"        cj_r = cast[uint64](19)")
            self.emit(f"    else:")
            self.emit(f"        cj_r = cast[uint64](23)")
            self._fold_value("cj_r", 19 if chain else 23)
            # value-use of the SAME chain boolean (must still materialize 0/1):
            self.emit(f"    cj_r = cast[uint64]({cond})")
            self._fold_value("cj_r", 1 if chain else 0)

        # ---- (7) comparison VALUE used directly (NOT a pure branch) -----------
        #      The value-use case the lever MUST leave materializing: a bare
        #      compare assigned to a local, and a compare used in arithmetic.
        for _ in range(rng.randint(1, 3)):
            op = rng.choice(OPS)
            signed = rng.random() < 0.5
            xv, yv = rng.choice(TRAP_PAIRS)
            xn, yn = load(signed, xv, yv)
            b = 1 if self._cmpjcc_eval(op, xv, yv, signed) else 0
            self.emit(f"    cj_r = cast[uint64]({xn} {op} {yn})")
            self._fold_value("cj_r", b)
            self.emit(f"    cj_r = cast[uint64]({xn} {op} {yn}) * cast[uint64](100)")
            self._fold_value("cj_r", (b * 100) & umask(64))

    # ======================================================================
    # Floating-point traffic (scalar SSE float32/float64). Emitted in BOTH
    # subset and default mode with an identical rng stream so the codegen.ad
    # differential gate exercises floats too. BIT-EXACT oracle: every float
    # value is integer-derived (cast[floatN](int)); every fold truncates the
    # float result back to a signed int (cast[int64](...)) which is then
    # widened to uint64 — so the predicted g_accum is the exact integer the
    # compiled code reaches. Values are kept small so float32's 24-bit
    # mantissa represents them exactly (no rounding divergence) and the
    # truncate-toward-zero (cvtt) result is unambiguous.
    # ======================================================================
    def _fp_int_src(self, v, ft):
        """Adder source for a float constant of value `v` (an int), as
        cast[ftname](int). Negative via (0 - n)."""
        if v < 0:
            return f"cast[{ft.name}](0 - {(-v)})"
        return f"cast[{ft.name}]({v})"

    def _gen_float_traffic(self, env):
        rng = self.rng
        # Two FP locals per float type, from small integers. float32 keeps
        # |v| < 2^23 so the value is mantissa-exact; products stay in range.
        for ft in FLOAT_TYPES:
            lim = 1000 if ft.bits == 32 else 100000
            av = rng.randint(-lim, lim)
            bv = rng.randint(1, lim)            # nonzero (used as divisor too)
            an = f"flt_a_{ft.name}"
            bn = f"flt_b_{ft.name}"
            self.emit(f"    {an}: {ft.name} = {self._fp_int_src(av, ft)}")
            self.emit(f"    {bn}: {ft.name} = {self._fp_int_src(bv, ft)}")
            # Python doubles snapped to the type model = the SSE register value.
            a = ft.round(float(av))
            b = ft.round(float(bv))
            # ---- arithmetic: +, -, * (all exact for these magnitudes) -------
            for k, (opsym, pyf) in enumerate(
                    (("+", a + b), ("-", a - b), ("*", a * b))):
                r = ft.round(pyf)
                ffn = f"flt_f_{ft.name}_{k}"
                self.emit(
                    f"    {ffn}: {ft.name} = {an} {opsym} {bn}")
                # truncate toward zero, fold the int64 bits widened to uint64.
                self._fold_value(
                    f"cast[uint64](cast[int64]({ffn}))",
                    U64.wrap(I64.wrap(int(r))))
            # ---- division: choose dividend a multiple of b so the quotient
            #      is an exact integer (no float32 rounding ambiguity) --------
            q = rng.randint(-50, 50)
            dividend = q * bv
            dn = f"flt_d_{ft.name}"
            qn = f"flt_q_{ft.name}"
            self.emit(f"    {dn}: {ft.name} = {self._fp_int_src(dividend, ft)}")
            self.emit(f"    {qn}: {ft.name} = {dn} / {bn}")
            dq = ft.round(ft.round(float(dividend)) / b)
            self._fold_value(f"cast[uint64](cast[int64]({qn}))",
                             U64.wrap(I64.wrap(int(dq))))
            # ---- negate (sign-bit flip) -------------------------------------
            nn = f"flt_n_{ft.name}"
            self.emit(f"    {nn}: {ft.name} = 0 - {an}")
            self._fold_value(f"cast[uint64](cast[int64]({nn}))",
                             U64.wrap(I64.wrap(int(ft.round(-a)))))
            # ---- compares: <, <=, >, >=, ==, != (ordered, never NaN) --------
            for opsym in ("<", "<=", ">", ">=", "==", "!="):
                cmp = {
                    "<": a < b, "<=": a <= b, ">": a > b, ">=": a >= b,
                    "==": a == b, "!=": a != b,
                }[opsym]
                self._fold_value(
                    f"cast[uint64](cast[int64]({an} {opsym} {bn}))",
                    U64.wrap(I64.wrap(1 if cmp else 0)))
        # ---- float32 <-> float64 conversion round trip ----------------------
        cv = rng.randint(-1000, 1000)
        self.emit(f"    flt_c32: float32 = {self._fp_int_src(cv, F32)}")
        self.emit("    flt_c64: float64 = cast[float64](flt_c32)")
        self._fold_value("cast[uint64](cast[int64](flt_c64))",
                         U64.wrap(I64.wrap(cv)))
        # int -> float -> int identity over a value exactly representable.
        iv = rng.randint(-100000, 100000)
        self.emit(f"    flt_i: float64 = cast[float64](cast[int64]({self._int_src(iv)}))")
        self._fold_value("cast[uint64](cast[int64](flt_i))",
                         U64.wrap(I64.wrap(iv)))
        # ---- NESTED float64 arith trees (exercise the float-SSE dest-driven
        #      selector's xmm-scratch recursion + the all-float64 path). Kept
        #      mantissa-exact: |a|,|b| <= 300 so products/sums stay << 2^53, so
        #      cast[int64] truncation is the exact integer the oracle predicts.
        #      These are DEPTH-2/3 trees the single-binop float traffic above does
        #      not reach. float64 ONLY (the selector ignores float32). -----------
        na = rng.randint(-300, 300)
        nb = rng.randint(1, 300)
        nc = rng.randint(-300, 300)
        nd = rng.randint(-300, 300)
        self.emit(f"    fn_a: float64 = cast[float64]({self._signed_lit(na)})")
        self.emit(f"    fn_b: float64 = cast[float64]({self._signed_lit(nb)})")
        self.emit(f"    fn_c: float64 = cast[float64]({self._signed_lit(nc)})")
        self.emit(f"    fn_d: float64 = cast[float64]({self._signed_lit(nd)})")
        fa = float(na); fb = float(nb); fc = float(nc); fd = float(nd)
        # depth-2: a*b + c    (mul then add)
        self.emit("    fn_g: float64 = fn_a * fn_b + fn_c")
        self._fold_value("cast[uint64](cast[int64](fn_g))",
                         U64.wrap(I64.wrap(int(fa * fb + fc))))
        # depth-2: (a + b) * (c - d)
        self.emit("    fn_h: float64 = (fn_a + fn_b) * (fn_c - fn_d)")
        self._fold_value("cast[uint64](cast[int64](fn_h))",
                         U64.wrap(I64.wrap(int((fa + fb) * (fc - fd)))))
        # depth-3: a*b + c*d - b   (two products, multiple scratch live at once)
        self.emit("    fn_k: float64 = fn_a * fn_b + fn_c * fn_d - fn_b")
        self._fold_value("cast[uint64](cast[int64](fn_k))",
                         U64.wrap(I64.wrap(int(fa * fb + fc * fd - fb))))
        # SELF-REFERENTIAL assign: the RHS reads the destination's OLD value
        # (the selector must read the home before the final store). fn_s = a, then
        # fn_s = fn_s * fn_b + fn_c.
        self.emit("    fn_s: float64 = fn_a")
        self.emit("    fn_s = fn_s * fn_b + fn_c")
        self._fold_value("cast[uint64](cast[int64](fn_s))",
                         U64.wrap(I64.wrap(int(fa * fb + fc))))
        # int-promotion leaf inside a float tree (cvtsi2sd operand).
        self.emit("    fn_p: float64 = fn_a * fn_b + cast[float64](7)")
        self._fold_value("cast[uint64](cast[int64](fn_p))",
                         U64.wrap(I64.wrap(int(fa * fb + 7.0))))

    def _signed_lit(self, v):
        """A bare signed integer literal (no cast wrapper) for `cast[float64](...)`."""
        if v < 0:
            return f"0 - {(-v)}"
        return f"{v}"

    def _int_src(self, v):
        if v < 0:
            return f"cast[int64](0 - {(-v)})"
        return f"cast[int64]({v})"


def render_program(seed, subset=False):
    p = Program(seed, subset=subset)
    body = p.build()
    return p, body


# --------------------------------------------------------------------------
# Compile + run driver.
# --------------------------------------------------------------------------
class RunResult:
    def __init__(self, kind, detail="", stdout="", exit=None):
        self.kind = kind      # "ok" | "crash" | "runfail"
        self.detail = detail
        self.stdout = stdout
        self.exit = exit


# Optimization level the fuzzer compiles each program at. 0 (default) exercises
# the trusted single-pass backend; set to 1 (via --opt 1 / ADDER_FUZZ_OPT=1) to
# run the SAME predicted-output oracle against the -O1 peephole optimizer
# (Track 6). Because the expected output is known by construction, a -O1 run
# that disagrees is an optimizer-introduced miscompile — the strongest possible
# correctness gate for the optimizer.
OPT_LEVEL = int(os.environ.get("ADDER_FUZZ_OPT", "0"))


def compile_and_run(seed, body, keep=False, target="x86_64-linux"):
    WORK.mkdir(parents=True, exist_ok=True)
    src = WORK / f"p_{seed}.ad"
    elf = WORK / f"p_{seed}.elf"
    src.write_text(body)
    rel_src = src.relative_to(REPO_ROOT)
    rel_elf = elf.relative_to(REPO_ROOT)
    cmd = [sys.executable, "-m", "compiler.adder", "compile",
           f"--target={target}", str(rel_src), "-o", str(rel_elf)]
    if OPT_LEVEL:
        cmd += ["-O", str(OPT_LEVEL)]
    cp = subprocess.run(cmd, cwd=str(REPO_ROOT), capture_output=True, text=True)
    if cp.returncode != 0:
        if not keep:
            src.unlink(missing_ok=True)
        return RunResult("crash", detail=(cp.stderr or cp.stdout)[-2000:])
    if not elf.exists():
        return RunResult("crash", detail="no ELF produced\n" + cp.stderr[-1000:])
    try:
        rp = subprocess.run([str(elf)], capture_output=True, text=True,
                            timeout=20)
    except subprocess.TimeoutExpired:
        if not keep:
            src.unlink(missing_ok=True); elf.unlink(missing_ok=True)
        return RunResult("runfail", detail="timeout")
    out = rp.stdout.strip()
    if not keep:
        src.unlink(missing_ok=True)
        elf.unlink(missing_ok=True)
    if rp.returncode < 0:
        return RunResult("runfail", detail=f"signal {-rp.returncode}",
                         stdout=out, exit=rp.returncode)
    return RunResult("ok", stdout=out, exit=rp.returncode & 0xFF)


# --------------------------------------------------------------------------
# SCAFFOLD: differential-mode hook (deliverable #4). The predicted-output
# oracle above is the PRIMARY mechanism and needs no second backend. But when
# a second backend (e.g. an LLVM path, or the Track-6 optimizer's output vs
# the un-optimized path) exists, the SAME generated program can be run through
# it and the two outputs cross-checked. To enable that, set the env var
# ADDER_FUZZ_DIFF_TARGET to an alternate `--target=` value (or a wrapper
# command); compile_and_run already takes the target as a parameter below.
# This is intentionally a thin seam, not a full second pipeline — the oracle
# catches miscompiles on its own; differential mode is a future force
# multiplier, especially for catching optimizer-introduced divergences where
# BOTH backends might agree with a buggy oracle but disagree with each other.
# --------------------------------------------------------------------------
DIFF_TARGET = None   # set by main() from --diff-target / env, e.g. a 2nd backend

# When True, each program is ALSO compiled + run through the self-hosted
# codegen.ad backend on the host (NO QEMU) via tests/fuzz/ad_codegen_host.py
# and its (stdout, exit) compared against the primary (Python-backend) result.
# Set by --ad-codegen / ADDER_FUZZ_DIFF_TARGET=ad-codegen. Programs codegen.ad
# cannot compile are classified "unsupported" (NOT a failure); only a program
# codegen.ad accepted that produced the wrong answer is a "differential"
# miscompile.
AD_CODEGEN = False
_AD_HOST = None          # lazily-imported ad_codegen_host module
_AD_WORK = None          # work dir for the codegen.ad ELFs

# ADDER_OPT=1 enables a NATIVE-OPTIMIZER correctness lane: codegen.ad is run
# with the Phase-1 optimizer (--opt) ON, and its output must still match the
# by-construction oracle (this is a CORRECTNESS check, not byte-identity vs
# the unoptimized output — the whole point of an optimizer is different bytes,
# same behavior). Default OFF: codegen.ad runs on its exact pre-opt path and
# the gate stays byte-exact against the seed.
ADDER_OPT = os.environ.get("ADDER_OPT", "0") not in ("", "0", "off", "false")
_AD_OPT_FOLDS_TOTAL = 0   # running fold count across the ADDER_OPT=1 lane
_AD_OPT_PROGS_FOLDED = 0  # programs in which >=1 fold fired
_AD_OPT_CSE_TOTAL = 0     # running CSE-elimination count across the lane
_AD_OPT_PROGS_CSE = 0     # programs in which >=1 CSE elimination fired
_AD_OPT_LICM_TOTAL = 0    # running LICM-hoist count across the lane
_AD_OPT_PROGS_LICM = 0    # programs in which >=1 LICM hoist fired
_AD_OPT_DCE_TOTAL = 0     # running DCE dead-local-removal count across the lane
_AD_OPT_PROGS_DCE = 0     # programs in which >=1 DCE removal fired
_AD_OPT_CONSTBRANCH_TOTAL = 0  # running const-branch-fold count across the lane
_AD_OPT_PROGS_CONSTBRANCH = 0  # programs in which >=1 const-branch fold fired
_AD_OPT_COPYPROP_TOTAL = 0     # running copy-propagation forward count across the lane
_AD_OPT_PROGS_COPYPROP = 0     # programs in which >=1 copy forward fired

# ADDER_CFG=1 enables the Phase-4 GROUNDWORK CFG/liveness lane: for every
# program codegen.ad's PARSER accepts, build the whole-function CFG + backward-
# dataflow liveness and assert the structural invariants (every block has a
# terminator; every edge endpoint exists; liveness reaches a fixpoint; no use-
# before-def of a non-live-in value within a block). This is PURE ANALYSIS — the
# driver's --dump-cfg mode returns before opt_run/codegen, so it cannot perturb
# codegen output. Default OFF. A `cfgfail` (broken invariant) fails the lane.
ADDER_CFG = os.environ.get("ADDER_CFG", "0") not in ("", "0", "off", "false")
_AD_CFG_FUNCS = 0         # functions the CFG builder processed
_AD_CFG_BLOCKS = 0        # total basic blocks built
_AD_CFG_EDGES = 0         # total CFG edges
_AD_CFG_INSTS = 0         # total CFG instructions
_AD_CFG_SKIPPED = 0       # functions skipped on arena overflow (not a failure)
_AD_CFG_PROGS = 0         # programs the CFG lane validated
_AD_CFG_FAILS = []        # (seed, detail) of broken-invariant programs
# Phase-4 PREREQ accumulators: value-level live ranges + alias/may-clobber.
_AD_CFG_RANGES = 0        # total valid live intervals (one per live name)
_AD_CFG_RANGE_LEN = 0     # sum of interval lengths (for avg)
_AD_CFG_RANGE_MAX = 0     # max single interval length across the corpus
_AD_CFG_LOCALS = 0        # total distinct interned names (locals/params)
_AD_CFG_PROMOTABLE = 0    # names register-promotable (not clobberable)
_AD_CFG_CLOBBERABLE = 0   # names clobberable (address-taken/stored-through)


def _ad_host():
    global _AD_HOST, _AD_WORK
    if _AD_HOST is None:
        import importlib
        _AD_HOST = importlib.import_module("ad_codegen_host")
        _AD_WORK = WORK / "ad_codegen"
    return _AD_HOST


def run_cfg_lane(seed, body):
    """Phase-4 GROUNDWORK: build+validate the CFG/liveness for `body`. Accumulates
    lane stats and records any broken-invariant program. Returns nothing; the
    batch driver reports the accumulated results + fails on any cfgfail."""
    global _AD_CFG_FUNCS, _AD_CFG_BLOCKS, _AD_CFG_EDGES, _AD_CFG_INSTS
    global _AD_CFG_SKIPPED, _AD_CFG_PROGS, _AD_CFG_FAILS
    global _AD_CFG_RANGES, _AD_CFG_RANGE_LEN, _AD_CFG_RANGE_MAX
    global _AD_CFG_LOCALS, _AD_CFG_PROMOTABLE, _AD_CFG_CLOBBERABLE
    host = _ad_host()
    try:
        r = host.run_cfg_over_body(seed, body, _AD_WORK)
    except Exception as e:
        _AD_CFG_FAILS.append((seed, f"cfg lane exception: {e!r}"))
        return
    if r.status in ("parsefail", "readfail", "drivererror"):
        # Not a CFG failure: the parser rejected the program (or tooling error);
        # the CFG lane only validates parser-accepted programs.
        return
    _AD_CFG_PROGS += 1
    _AD_CFG_FUNCS += r.funcs
    _AD_CFG_BLOCKS += r.blocks
    _AD_CFG_EDGES += r.edges
    _AD_CFG_INSTS += r.insts
    _AD_CFG_SKIPPED += r.skipped
    _AD_CFG_RANGES += r.ranges
    _AD_CFG_RANGE_LEN += r.range_len
    if r.range_max > _AD_CFG_RANGE_MAX:
        _AD_CFG_RANGE_MAX = r.range_max
    _AD_CFG_LOCALS += r.locals
    _AD_CFG_PROMOTABLE += r.promotable
    _AD_CFG_CLOBBERABLE += r.clobberable
    if r.status == "cfgfail":
        _AD_CFG_FAILS.append((seed, r.detail))


def run_through_ad_codegen(seed, body):
    """Compile+run `body` through codegen.ad on the host. Returns a tuple:
      ("unsupported", detail)          codegen.ad rejected (out of subset)
      ("ok", stdout, exit)             codegen.ad compiled + ran
      ("__ad_error__", kind, detail)   driver/run error (not a miscompile)

    When ADDER_OPT is set, the native Phase-1 optimizer (--opt) is enabled and
    its fold count accumulated; the (stdout, exit) returned must still match
    the oracle (caller asserts correctness)."""
    global _AD_OPT_FOLDS_TOTAL, _AD_OPT_PROGS_FOLDED
    global _AD_OPT_CSE_TOTAL, _AD_OPT_PROGS_CSE
    global _AD_OPT_LICM_TOTAL, _AD_OPT_PROGS_LICM
    global _AD_OPT_DCE_TOTAL, _AD_OPT_PROGS_DCE
    global _AD_OPT_CONSTBRANCH_TOTAL, _AD_OPT_PROGS_CONSTBRANCH
    global _AD_OPT_COPYPROP_TOTAL, _AD_OPT_PROGS_COPYPROP
    host = _ad_host()
    r = host.run_through_codegen_ad(seed, body, _AD_WORK, opt=ADDER_OPT)
    if r.kind == "unsupported":
        return ("unsupported", r.detail)
    if r.kind == "ok":
        if ADDER_OPT:
            f = int(getattr(r, "folds", 0) or 0)
            _AD_OPT_FOLDS_TOTAL += f
            if f > 0:
                _AD_OPT_PROGS_FOLDED += 1
            c = int(getattr(r, "cse", 0) or 0)
            _AD_OPT_CSE_TOTAL += c
            if c > 0:
                _AD_OPT_PROGS_CSE += 1
            lc = int(getattr(r, "licm", 0) or 0)
            _AD_OPT_LICM_TOTAL += lc
            if lc > 0:
                _AD_OPT_PROGS_LICM += 1
            dc = int(getattr(r, "dce", 0) or 0)
            _AD_OPT_DCE_TOTAL += dc
            if dc > 0:
                _AD_OPT_PROGS_DCE += 1
            cb = int(getattr(r, "constbranch", 0) or 0)
            _AD_OPT_CONSTBRANCH_TOTAL += cb
            if cb > 0:
                _AD_OPT_PROGS_CONSTBRANCH += 1
            cp = int(getattr(r, "copyprop", 0) or 0)
            _AD_OPT_COPYPROP_TOTAL += cp
            if cp > 0:
                _AD_OPT_PROGS_COPYPROP += 1
        return ("ok", r.stdout, r.exit)
    return ("__ad_error__", r.kind, r.detail)


def run_differential(seed, body):
    """If a second backend/target is configured, compile+run the same program
    through it and return its (stdout, exit) for cross-check. Returns None when
    no second target is configured (the default)."""
    if DIFF_TARGET is None:
        return None
    res = compile_and_run(seed, body, target=DIFF_TARGET)
    if res.kind != "ok":
        return ("__diff_error__", res.kind, res.detail)
    return (res.stdout, res.exit)


def check_one_ad_codegen(seed):
    """Differential check against the self-hosted codegen.ad backend.

    Generates a SUBSET program (no 2-D array global — codegen.ad's only
    relevant gap), compiles+runs it through BOTH the trusted Python backend
    (the oracle is by-construction) AND codegen.ad on the host, and compares.

    Returns (kind, seed, detail, body) where kind is one of:
      "ok"           : codegen.ad accepted and matched the oracle
      "unsupported"  : codegen.ad rejected the program (out of subset)
      "differential" : codegen.ad accepted but produced the WRONG output
                       (a genuine codegen.ad miscompile) -- the only failure
      "py-miscompile": the PYTHON backend itself disagreed with the oracle
                       (should never happen; surfaces a primary-backend bug)
      "crash"/"runfail"/"ad-error": tooling/run errors (not codegen.ad bugs)
    """
    p, body = render_program(seed, subset=True)
    # Primary: the trusted Python backend must match the by-construction oracle.
    res = compile_and_run(seed, body)
    if res.kind == "crash":
        return ("crash", seed, "python-backend " + res.detail, body)
    if res.kind == "runfail":
        return ("runfail", seed, "python-backend " + res.detail, body)
    if res.stdout != p.expected_stdout or res.exit != p.expected_exit:
        return ("py-miscompile", seed,
                f"python actual=({res.stdout},{res.exit}) "
                f"oracle=({p.expected_stdout},{p.expected_exit})", body)
    # Secondary: codegen.ad.
    ad = run_through_ad_codegen(seed, body)
    if ad[0] == "unsupported":
        return ("unsupported", seed, ad[1], body)
    if ad[0] == "__ad_error__":
        return ("ad-error", seed, f"{ad[1]}: {ad[2]}", body)
    ad_stdout, ad_exit = ad[1], ad[2]
    if (ad_stdout, ad_exit) != (p.expected_stdout, p.expected_exit):
        return ("differential", seed,
                f"codegen.ad=({ad_stdout},{ad_exit}) "
                f"oracle/python=({p.expected_stdout},{p.expected_exit})", body)
    return ("ok", seed, "", body)


def check_one(seed):
    if AD_CODEGEN:
        return check_one_ad_codegen(seed)
    p, body = render_program(seed)
    res = compile_and_run(seed, body)
    if res.kind == "crash":
        return ("crash", seed, res.detail, body)
    if res.kind == "runfail":
        return ("runfail", seed, res.detail, body)
    if res.stdout != p.expected_stdout:
        return ("miscompile", seed,
                f"stdout actual={res.stdout!r} expected={p.expected_stdout!r}",
                body)
    if res.exit != p.expected_exit:
        return ("miscompile", seed,
                f"exit actual={res.exit} expected={p.expected_exit} "
                f"(stdout matched={res.stdout})", body)
    # Optional differential cross-check against a second backend/target. The
    # oracle already passed; this catches a divergence where the second
    # backend disagrees (primarily useful once an optimizer/2nd backend
    # exists). No-op unless --diff-target / ADDER_FUZZ_DIFF_TARGET is set.
    diff = run_differential(seed, body)
    if diff is not None and diff[0] != "__diff_error__":
        if diff != (res.stdout, res.exit):
            return ("differential", seed,
                    f"primary=({res.stdout},{res.exit}) "
                    f"diff-target=({diff[0]},{diff[1]})", body)
    return ("ok", seed, "", body)


# --------------------------------------------------------------------------
# Phase-2 CSE corpus. Hand-written programs with REPEATED non-constant pure
# subexpressions (the kind local CSE/value-numbering targets), each computing a
# known value. Run through codegen.ad WITH --opt; the optimized output must
# match the Python-computed oracle AND the CSE pass must fire. The repeated
# subexpressions are over the signedness-invariant 64-bit op set (ADD/SUB/MUL/
# AND/OR/XOR/SHL) over parameters/locals — exactly the CSE-safe leaf set.
# --------------------------------------------------------------------------
def _cse_corpus():
    """Return a list of (name, body, expected_stdout, expected_exit)."""
    M = (1 << 64) - 1
    progs = []

    def prog(name, decls_and_main, val):
        # val = the uint64 g_accum the program prints; exit = val & 255.
        body = PRELUDE + "\n" + decls_and_main
        progs.append((name, body, str(val & M), (val & 255)))

    # 1) Same product appears twice in one expression: (a*b) + (a*b).
    a, b = 6, 7
    v = (a * b) + (a * b)
    prog("dup_mul_add",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         f"    a: uint64 = cast[uint64]({a})\n"
         f"    b: uint64 = cast[uint64]({b})\n"
         "    g_accum = (a * b) + (a * b)\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         v)

    # 2) Repeated sum subexpression three times: (a+b) ^ (a+b) ^ (a+b).
    a, b = 0x1234, 0x9abc
    s = (a + b) & M
    v = (s ^ s ^ s) & M
    prog("dup_add_xor3",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         f"    a: uint64 = cast[uint64]({a})\n"
         f"    b: uint64 = cast[uint64]({b})\n"
         "    g_accum = ((a + b) ^ (a + b)) ^ (a + b)\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         v)

    # 3) Nested repeated subexpression: ((a*b)+c) twice -> the inner (a*b) AND
    #    the outer ((a*b)+c) both recur; CSE should pick the maximal one.
    a, b, c = 3, 5, 9
    t = ((a * b) + c) & M
    v = (t + t) & M
    prog("dup_nested",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         f"    a: uint64 = cast[uint64]({a})\n"
         f"    b: uint64 = cast[uint64]({b})\n"
         f"    c: uint64 = cast[uint64]({c})\n"
         "    g_accum = ((a * b) + c) + ((a * b) + c)\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         v)

    # 4) Repeated shift-and-or in a return expression over parameters. Both the
    #    shift amount and base are IDENT leaves (CSE-safe), so (x << s) recurs.
    a, sft = 0xff, 3
    sh = ((a << sft) | (a << sft)) & M
    v = sh & M
    prog("dup_shl_or",
         "def compute(x: uint64, s: uint64) -> uint64:\n"
         "    return (x << s) | (x << s)\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         f"    g_accum = compute(cast[uint64]({a}), cast[uint64]({sft}))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         v)

    return progs


def _run_cse_corpus():
    """Run the CSE corpus through codegen.ad with --opt. Returns
    (all_correct_and_fired, total_cse_eliminations)."""
    host = _ad_host()
    total_cse = 0
    all_ok = True
    for (name, body, exp_out, exp_exit) in _cse_corpus():
        r = host.run_through_codegen_ad(f"cse_{name}", body, _AD_WORK, opt=True)
        if r.kind != "ok":
            all_ok = False
            print(f"  [CSE corpus '{name}'] codegen.ad {r.kind}: {r.detail[:120]}")
            continue
        c = int(getattr(r, "cse", 0) or 0)
        total_cse += c
        if r.stdout != exp_out or r.exit != exp_exit:
            all_ok = False
            print(f"  [CSE corpus '{name}'] MISCOMPILE opt=("
                  f"{r.stdout},{r.exit}) oracle=({exp_out},{exp_exit}) cse={c}")
        elif c == 0:
            all_ok = False
            print(f"  [CSE corpus '{name}'] correct but CSE NEVER FIRED")
    # The corpus only passes if every program was correct AND the pass fired at
    # least once across it.
    if total_cse == 0:
        all_ok = False
    return (all_ok, total_cse)


# --------------------------------------------------------------------------
# DCE call-argument corpus (regression for the 2nd+-call-arg use-undercount).
#
# Phase-8 DCE counts the uses of a pure local before deleting its decl. The use
# counter (dce_count_expr) walked only nd_a..nd_d and NOT the nd_next operand
# chain, so a name used ONLY as the 2nd-or-later argument of a call (`f(a, x)`,
# where x lives at the args-head's nd_next) was counted ZERO times — DCE deleted
# its decl, and codegen then had no frame slot for it: a `STATUS cgfail` ABORT
# under --opt for a program that compiled fine WITHOUT --opt (and, when the name
# shadowed a global/param, a silent wrong-storage MISCOMPILE). These programs
# pin the fix: each compiles + runs correctly ON and OFF, and a genuinely-dead
# local keeps DCE firing so the corpus proves the pass is still exercised.
# --------------------------------------------------------------------------
def _dce_callarg_corpus():
    """Return a list of (name, body, expected_stdout, expected_exit, want_dce)."""
    M = (1 << 64) - 1
    progs = []

    def prog(name, decls_and_main, val, want_dce):
        body = PRELUDE + "\n" + decls_and_main
        progs.append((name, body, str(val & M), (val & 255), want_dce))

    # 1) THE REPRO: three locals passed as the 1st/2nd/3rd args of a call and
    #    used NOWHERE else. Pre-fix: y and z (2nd/3rd args) counted 0 -> DCE
    #    deleted their decls -> cgfail. Must compile + return 3+4+5 = 12.
    prog("three_locals_args",
         "def add3(a: int64, b: int64, c: int64) -> int64:\n"
         "    return a + b + c\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    x: int64 = 3\n"
         "    y: int64 = 4\n"
         "    z: int64 = 5\n"
         "    g_accum = cast[uint64](add3(x, y, z))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         12, 0)

    # 2) A local used ONLY as the 2nd argument (1st arg is a literal), PLUS a
    #    genuinely-dead pure local so DCE still fires (and the corpus proves it).
    prog("second_arg_plus_dead",
         "def use2(a: int64, b: int64) -> int64:\n"
         "    return a * b\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    q: int64 = 7\n"
         "    dead: int64 = 99\n"
         "    g_accum = cast[uint64](use2(6, q))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         42, 1)

    # 3) A local used ONLY as the 3rd argument behind two literals.
    prog("third_arg_only",
         "def add3(a: int64, b: int64, c: int64) -> int64:\n"
         "    return a + b + c\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    k: int64 = 10\n"
         "    g_accum = cast[uint64](add3(1, 2, k))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         13, 0)

    # 4) NESTED call: the inner call's 1st/2nd args are locals used only there
    #    (the inner call is itself the outer call's 1st argument, an nd_next
    #    operand was missed at two levels). (8+9)+5 = 22.
    prog("nested_call_args",
         "def add2(a: int64, b: int64) -> int64:\n"
         "    return a + b\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    m: int64 = 8\n"
         "    n: int64 = 9\n"
         "    g_accum = cast[uint64](add2(add2(m, n), 5))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         22, 0)

    return progs


def _run_dce_callarg_corpus():
    """Run the DCE call-arg corpus through codegen.ad ON and OFF. Returns
    (all_ok, total_dce_eliminations). Each program must compile + run correctly
    WITH --opt (the regression) and WITHOUT it, the OFF path must be DCE-inert
    (dce==0), and DCE must fire at least once across the corpus (a real dead
    local was reclaimed) so the corpus proves the pass is still exercised."""
    host = _ad_host()
    total_dce = 0
    all_ok = True
    for (name, body, exp_out, exp_exit, want_dce) in _dce_callarg_corpus():
        # WITH --opt: the regression. A pre-fix build returns kind=="unsupported"
        # (STATUS cgfail) for the 2nd+-arg programs; the fix makes them compile.
        r = host.run_through_codegen_ad(f"dcecallarg_{name}", body, _AD_WORK, opt=True)
        if r.kind != "ok":
            all_ok = False
            print(f"  [DCE callarg '{name}'] codegen.ad {r.kind}: {r.detail[:120]}")
            continue
        d = int(getattr(r, "dce", 0) or 0)
        total_dce += d
        if r.stdout != exp_out or r.exit != exp_exit:
            all_ok = False
            print(f"  [DCE callarg '{name}'] MISCOMPILE opt=("
                  f"{r.stdout},{r.exit}) oracle=({exp_out},{exp_exit}) dce={d}")
        # WITHOUT --opt: must run correctly AND be DCE-inert.
        r0 = host.run_through_codegen_ad(f"dcecallarg_{name}_off", body, _AD_WORK, opt=False)
        if r0.kind != "ok" or r0.stdout != exp_out or r0.exit != exp_exit:
            all_ok = False
            print(f"  [DCE callarg '{name}'] OFF path wrong: kind={r0.kind} "
                  f"out=({r0.stdout},{r0.exit}) oracle=({exp_out},{exp_exit})")
        elif int(getattr(r0, "dce", 0) or 0) != 0:
            all_ok = False
            print(f"  [DCE callarg '{name}'] OFF not DCE-inert (dce="
                  f"{getattr(r0, 'dce', 0)})")
    # The pass must have fired somewhere (the genuinely-dead local in case 2).
    if total_dce == 0:
        all_ok = False
        print("  [DCE callarg] DCE never fired across the corpus")
    return (all_ok, total_dce)


# --------------------------------------------------------------------------
# nd_next SIBLING-CHAIN traversal corpus (whole-class guard).
#
# An expression OPERAND LIST — a call/method-call ARGUMENT list, an array/dict-
# literal ELEMENT list — is an nd_next-linked sibling chain hanging off ONE child
# slot of the parent node, NOT the fixed nd_a..nd_d slots. Several optimizer AST
# walkers historically descended only nd_a..nd_d and so analysed ONLY the FIRST
# operand, silently mis-analysing every LATER sibling. The first instance (#507)
# was DCE use-counting (a local used only as a 2nd+ call arg counted ZERO uses ->
# its decl was deleted -> cgfail/miscompile); the _dce_callarg_corpus guards that.
#
# This corpus guards the WHOLE class across the other passes by exercising values
# that live ONLY in a later sibling position (2nd/3rd call args, nested calls in
# arg position, names that shadow a param), feeding copy-prop / CSE / LICM. Each
# program must compile + run correctly ON and OFF, with OFF == ON == oracle.
#
# It ALSO pins a SECOND, independent reachable --opt miscompile found in the same
# audit: a METHOD CALL `obj.m(...)` (ND_METHOD_CALL) was NOT recognised as a
# side-effect barrier by the optimizer's expression scanner (licm_scan_expr,
# shared by load-CSE / copy-prop / LICM), which only short-circuited ND_CALL. A
# load held across a mutating method call was therefore reused STALE — a silent
# load-CSE miscompile. The `loadcse_across_method` shapes return WRONG under a
# pre-fix build and CORRECT after; OFF is always correct (no opt).
# --------------------------------------------------------------------------
def _ndnext_corpus():
    """Return a list of (name, full_body, expected_stdout, expected_exit)."""
    M = (1 << 64) - 1
    progs = []

    def prog(name, decls_and_main, val):
        body = PRELUDE + "\n" + decls_and_main
        progs.append((name, body, str(val & M), (val & 255)))

    # Self-contained byte I/O for the class/method shapes (no PRELUDE; the only
    # functions present are the I/O helpers + the class under test).
    IO = (
        "extern def sys_write(fd: int32, buf: Ptr[uint8], count: uint64) -> int64\n"
        "_ch: Array[1, uint8]\n"
        "def _putc(c: uint8) -> int32:\n"
        "    _ch[0] = c\n"
        "    sys_write(cast[int32](1), &_ch[0], cast[uint64](1))\n"
        "    return 0\n"
    )

    def prog_raw(name, body, out, ex):
        progs.append((name, body, out, ex))

    # 1) COPY-PROP forwarded into a 2nd + 3rd call argument (a copy chain whose
    #    dests live ONLY in later arg positions). 1 + 11 + 11 = 23.
    prog("cp_chain_args",
         "def add3(a: int64, b: int64, c: int64) -> int64:\n"
         "    return a + b + c\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    b: int64 = 11\n"
         "    a: int64 = b\n"
         "    c: int64 = a\n"
         "    g_accum = cast[uint64](add3(1, a, c))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](g_accum & cast[uint64](255))\n",
         23)

    # 2) CSE: identical pure subexpression x*y in the 2nd AND 3rd args. 0+42+42.
    prog("cse_dup_args",
         "def add3(a: int64, b: int64, c: int64) -> int64:\n"
         "    return a + b + c\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    x: int64 = 6\n"
         "    y: int64 = 7\n"
         "    g_accum = cast[uint64](add3(0, x * y, x * y))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](g_accum & cast[uint64](255))\n",
         84)

    # 3) NESTED call: the inner call is the OUTER call's 2nd argument, and the
    #    inner call's own args are locals used nowhere else. 5 + (8+9) = 22.
    prog("nested_call_2nd",
         "def add2(a: int64, b: int64) -> int64:\n"
         "    return a + b\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    m: int64 = 8\n"
         "    n: int64 = 9\n"
         "    g_accum = cast[uint64](add2(5, add2(m, n)))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](g_accum & cast[uint64](255))\n",
         22)

    # 4) LICM: a loop-invariant product p*q used ONLY as a call's 2nd argument
    #    inside the loop. sum(i,0..4) + 5*(3*4) = 10 + 60 = 70.
    prog("licm_inv_2nd_arg",
         "def add2(a: int64, b: int64) -> int64:\n"
         "    return a + b\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    p: int64 = 3\n"
         "    q: int64 = 4\n"
         "    acc: int64 = 0\n"
         "    i: int64 = 0\n"
         "    while i < 5:\n"
         "        acc = acc + add2(i, p * q)\n"
         "        i = i + 1\n"
         "    g_accum = cast[uint64](acc)\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](g_accum & cast[uint64](255))\n",
         70)

    # 5) SHADOW trigger: a parameter `b` and a local `b2` are each used ONLY in a
    #    later arg position; the shadow case is the silent-miscompile path of the
    #    DCE class. 0 + 20 + 21 = 41.
    prog("shadow_param_later_arg",
         "def add3(a: int64, b: int64, c: int64) -> int64:\n"
         "    return a + b + c\n"
         "def helper(b: int64) -> int64:\n"
         "    b2: int64 = b + 1\n"
         "    return add3(0, b, b2)\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    g_accum = cast[uint64](helper(20))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](g_accum & cast[uint64](255))\n",
         41)

    # 6) METHOD-CALL BARRIER (load-CSE): `garr[0]` is loaded, a mutating method
    #    `o.bump()` is called, then `garr[0]` is reloaded. The optimizer must
    #    treat the ND_METHOD_CALL as a side-effect barrier and FLUSH the held
    #    load; a pre-fix build reused the stale (pre-call) value. The object is
    #    constructed BEFORE the first load so ONLY the method call sits between
    #    the two reads (the constructor call is itself an ND_CALL barrier).
    #    a = garr[0]+7 = 12 (garr[0]==5), bump -> garr[0]=105, b = garr[0] = 105;
    #    return (a+b)&255 = 117.
    bumper = (
        IO
        + "garr: Array[8, int64]\n"
        + "class Bumper:\n"
        + "    tag: int64\n"
        + "    def __init__(self):\n"
        + "        self.tag = cast[int64](0)\n"
        + "    def bump(self) -> int64:\n"
        + "        garr[0] = garr[0] + 100\n"
        + "        return garr[0]\n"
        + "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
        + "    o: Bumper = Bumper()\n"
        + "    garr[0] = cast[int64](5)\n"
        + "    a: int64 = garr[0] + cast[int64](7)\n"
        + "    junk: int64 = o.bump()\n"
        + "    b: int64 = garr[0] + cast[int64](0)\n"
        + "    return cast[int32]((a + b) & cast[int64](255))\n"
    )
    prog_raw("loadcse_across_method", bumper, "", 117)

    # NOTE: a LOOP variant (a value live across a method call inside a loop) is
    # deliberately NOT included here. It exposes a SEPARATE, pre-existing codegen
    # bug — gen_method emits a prologue whose saved callee-saved set does not match
    # the registers its body allocates (it clobbers e.g. %r13 without saving it),
    # corrupting a caller value the allocator parked there across the call (only
    # observable under --opt, when store-to-slot is elided). That belongs to the
    # register-allocation/method-prologue subsystem, not the optimizer's AST
    # sibling-chain / call-barrier traversal this corpus guards, and is escalated
    # separately so this corpus stays a clean green guard for THIS class.

    return progs


def _run_ndnext_corpus():
    """Run the nd_next sibling-chain corpus through codegen.ad ON and OFF. Every
    program must compile + run correctly WITH --opt (the regression guard) AND
    WITHOUT it, and ON must equal OFF must equal the oracle. Returns
    (all_ok, n_programs)."""
    host = _ad_host()
    all_ok = True
    n = 0
    for (name, body, exp_out, exp_exit) in _ndnext_corpus():
        n += 1
        r = host.run_through_codegen_ad(f"ndnext_{name}", body, _AD_WORK, opt=True)
        if r.kind != "ok":
            all_ok = False
            print(f"  [ndnext '{name}'] codegen.ad {r.kind}: {r.detail[:140]}")
            continue
        if r.stdout != exp_out or r.exit != exp_exit:
            all_ok = False
            print(f"  [ndnext '{name}'] --opt MISCOMPILE on=("
                  f"{r.stdout!r},{r.exit}) oracle=({exp_out!r},{exp_exit}) "
                  f"loadcse={r.loadcse} cse={r.cse} copyprop={r.copyprop} licm={r.licm}")
        r0 = host.run_through_codegen_ad(f"ndnext_{name}_off", body, _AD_WORK, opt=False)
        if r0.kind != "ok" or r0.stdout != exp_out or r0.exit != exp_exit:
            all_ok = False
            print(f"  [ndnext '{name}'] OFF path wrong: kind={r0.kind} "
                  f"out=({r0.stdout!r},{r0.exit}) oracle=({exp_out!r},{exp_exit})")
    return (all_ok, n)


# --------------------------------------------------------------------------
# Phase-3 LICM corpus. Hand-written programs with LOOP-INVARIANT pure
# subexpressions inside while/for loop bodies. Run through codegen.ad WITH --opt;
# the optimized output must match the Python-computed oracle AND the LICM pass
# must hoist (>=1 pre-header materialisation across the corpus). The invariant
# subexpressions are over the signedness-invariant 64-bit op set (ADD/SUB/MUL/
# AND/OR/XOR/SHL) over loop-EXTERNAL idents — exactly the hoistable leaf set.
# Each program also includes a leaf whose value DOES change in the loop, so a
# buggy "hoist everything" pass would miscompile and be caught by the oracle.
# --------------------------------------------------------------------------
def _licm_corpus():
    """Return a list of (name, body, expected_stdout, expected_exit)."""
    M = (1 << 64) - 1
    progs = []

    def prog(name, decls_and_main, val):
        body = PRELUDE + "\n" + decls_and_main
        progs.append((name, body, str(val & M), (val & 255)))

    # 1) while loop: (a*b) is invariant (a,b never written); accumulate it each
    #    iteration. i is the induction var (written) so it is NOT hoisted.
    a, b, n = 6, 7, 5
    inv = (a * b) & M
    v = 0
    i = 0
    while i < n:
        v = (v + inv) & M
        i += 1
    prog("while_inv_mul",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         f"    a: uint64 = cast[uint64]({a})\n"
         f"    b: uint64 = cast[uint64]({b})\n"
         f"    n: uint64 = cast[uint64]({n})\n"
         "    i: uint64 = cast[uint64](0)\n"
         "    while i < n:\n"
         "        g_accum = g_accum + (a * b)\n"
         "        i = i + cast[uint64](1)\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         v)

    # 2) Invariant expr mixes invariant idents with the induction var: hoist the
    #    invariant (k+m) part only; (i + (k+m)) is NOT invariant (i changes).
    k, m, n = 100, 23, 4
    invk = (k + m) & M
    v = 0
    i = 0
    while i < n:
        v = (v + (i + invk)) & M
        i += 1
    prog("while_partial_inv",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         f"    k: uint64 = cast[uint64]({k})\n"
         f"    m: uint64 = cast[uint64]({m})\n"
         f"    n: uint64 = cast[uint64]({n})\n"
         "    i: uint64 = cast[uint64](0)\n"
         "    while i < n:\n"
         "        g_accum = g_accum + (i + (k + m))\n"
         "        i = i + cast[uint64](1)\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         v)

    # 3) NESTED loops: (p*q) is invariant w.r.t. BOTH loops; (p*q)+j is invariant
    #    w.r.t the inner loop only (j is the outer induction var, unchanged
    #    inside the inner body) so it hoists to the INNER pre-header.
    p, q, no, ni = 3, 9, 3, 4
    invpq = (p * q) & M
    v = 0
    j = 0
    while j < no:
        ii = 0
        while ii < ni:
            v = (v + (invpq + j)) & M
            ii += 1
        j += 1
    prog("nested_inner_inv",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         f"    p: uint64 = cast[uint64]({p})\n"
         f"    q: uint64 = cast[uint64]({q})\n"
         f"    no: uint64 = cast[uint64]({no})\n"
         f"    ni: uint64 = cast[uint64]({ni})\n"
         "    j: uint64 = cast[uint64](0)\n"
         "    while j < no:\n"
         "        ii: uint64 = cast[uint64](0)\n"
         "        while ii < ni:\n"
         "            g_accum = g_accum + ((p * q) + j)\n"
         "            ii = ii + cast[uint64](1)\n"
         "        j = j + cast[uint64](1)\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         v)

    # 4) ZERO-TRIP loop: the loop runs zero times, so the invariant (a*b) must
    #    NOT be observable — but hoisting a pure non-faulting value above it is
    #    safe (the temp is computed and unused). The accumulator stays 0; the
    #    correctness check proves the hoist didn't introduce a spurious effect.
    a, b = 11, 13
    v = 0  # loop body never runs
    prog("zero_trip_safe",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         f"    a: uint64 = cast[uint64]({a})\n"
         f"    b: uint64 = cast[uint64]({b})\n"
         "    n: uint64 = cast[uint64](0)\n"
         "    i: uint64 = cast[uint64](0)\n"
         "    while i < n:\n"
         "        g_accum = g_accum + (a * b)\n"
         "        i = i + cast[uint64](1)\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         v)

    # 5) Body REASSIGNS a leaf of an otherwise-pure expr: (a*b) where `a` is
    #    rewritten in the loop is NOT invariant and must NOT be hoisted. The
    #    oracle (a changes each iter) catches a wrongly-hoisted stale value.
    a0, b, n = 2, 5, 4
    v = 0
    a = a0
    i = 0
    while i < n:
        v = (v + (a * b)) & M
        a = (a + 1) & M
        i += 1
    prog("clobbered_leaf_no_hoist",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         f"    a: uint64 = cast[uint64]({a0})\n"
         f"    b: uint64 = cast[uint64]({b})\n"
         f"    n: uint64 = cast[uint64]({n})\n"
         "    i: uint64 = cast[uint64](0)\n"
         "    while i < n:\n"
         "        g_accum = g_accum + (a * b)\n"
         "        a = a + cast[uint64](1)\n"
         "        i = i + cast[uint64](1)\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         v)

    return progs


def _run_licm_corpus():
    """Run the LICM corpus through codegen.ad with --opt. Returns
    (all_correct_and_fired, total_licm_hoists)."""
    host = _ad_host()
    total_licm = 0
    all_ok = True
    for (name, body, exp_out, exp_exit) in _licm_corpus():
        r = host.run_through_codegen_ad(f"licm_{name}", body, _AD_WORK, opt=True)
        if r.kind != "ok":
            all_ok = False
            print(f"  [LICM corpus '{name}'] codegen.ad {r.kind}: {r.detail[:120]}")
            continue
        lc = int(getattr(r, "licm", 0) or 0)
        total_licm += lc
        if r.stdout != exp_out or r.exit != exp_exit:
            all_ok = False
            print(f"  [LICM corpus '{name}'] MISCOMPILE opt=("
                  f"{r.stdout},{r.exit}) oracle=({exp_out},{exp_exit}) licm={lc}")
    # The corpus only passes if every program was correct AND the pass hoisted at
    # least once across it (the clobbered/partial cases prove it DOESN'T over-
    # hoist; the invariant cases prove it DOES fire).
    if total_licm == 0:
        all_ok = False
    return (all_ok, total_licm)


# --------------------------------------------------------------------------
# Phase-5 IR-EMIT corpus. Hand-written programs whose hot expressions lower
# FULLY into the value IR (ir_lower_pure_expr) — pure signedness-invariant
# integer arithmetic over ident/const leaves — so codegen emits them by walking
# the IR TREE (gen_expr_ir) instead of the AST. Each program:
#   * is correct vs a Python uint64 oracle (the IR-emitted code must produce the
#     SAME value as the seed — the whole point of a sound IR path),
#   * demonstrably went THROUGH the IR emitter (IREMIT marker > 0, not the AST
#     fallback),
#   * for the reassociation cases, the IR emitter collapsed an ADD chain's
#     constant tail into one immediate (IRREASSOC marker > 0) — a reduction the
#     AST const-fold pass cannot make ((a+3)+4 -> a+7) — AND the ON image is
#     strictly SMALLER than (or differs from) the OFF image, proving the IR
#     optimization reached the machine code,
#   * is byte-INERT with --opt OFF (no IR path; the run's IREMIT must be 0).
# --------------------------------------------------------------------------
def _iremit_corpus():
    """Return a list of (name, body, expected_stdout, expected_exit, want_reassoc)."""
    M = (1 << 64) - 1
    progs = []

    def prog(name, decls_and_main, val, want_reassoc):
        body = PRELUDE + "\n" + decls_and_main
        progs.append((name, body, str(val & M), (val & 255), want_reassoc))

    # 1) Pure integer arithmetic tree over params -> lowers fully, emits via IR.
    a, b, c = 11, 5, 3
    v = (((a * b) + c) ^ (b << c)) & M
    prog("pure_arith_tree",
         "def compute(a: uint64, b: uint64, c: uint64) -> uint64:\n"
         "    return ((a * b) + c) ^ (b << c)\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         f"    g_accum = compute(cast[uint64]({a}), cast[uint64]({b}), cast[uint64]({c}))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         v, 0)

    # 2) ADD constant-tail reassociation: (a + 3) + 4 -> a + 7 (one immediate).
    a = 100
    v = ((a + 3) + 4) & M
    prog("reassoc_add2",
         "def f(a: uint64) -> uint64:\n"
         "    return (a + 3) + 4\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         f"    g_accum = f(cast[uint64]({a}))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         v, 1)

    # 3) Deeper ADD chain with constants scattered: ((((a+1)+b)+2)+3) -> a+b+6.
    a, b = 40, 7
    v = (((((a + 1) + b) + 2) + 3)) & M
    prog("reassoc_add_chain",
         "def g(a: uint64, b: uint64) -> uint64:\n"
         "    return (((((a + 1) + b) + 2) + 3))\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         f"    g_accum = g(cast[uint64]({a}), cast[uint64]({b}))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         v, 1)

    # 4) Reassociation inside a hot loop body (also LICM/CSE-interacting):
    #    acc += ((x + 1) + 2) each iter. The reassoc collapses the addend to x+3.
    n, x = 6, 9
    acc = 0
    for _ in range(n):
        acc = (acc + (((x + 1) + 2))) & M
    prog("reassoc_loop",
         "def hot(n: uint64, x: uint64) -> uint64:\n"
         "    acc: uint64 = cast[uint64](0)\n"
         "    i: uint64 = cast[uint64](0)\n"
         "    while i < n:\n"
         "        acc = acc + (((x + 1) + 2))\n"
         "        i = i + cast[uint64](1)\n"
         "    return acc\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         f"    g_accum = hot(cast[uint64]({n}), cast[uint64]({x}))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         acc, 1)

    # ---- Phase 6: broadened lowered set — compares + DIV/MOD/SHR. Each lowers
    #      fully into the value IR and emits THROUGH gen_expr_ir (IREMIT>0).
    #      These pin the signed-vs-unsigned + negative-dividend traps that are
    #      the classic miscompiles for the cmp/setcc and cqo/idiv/sar paths. ----

    # 5) UNSIGNED compare whose result FLIPS under a signed reading: (uint64)-1
    #    > 1 is True unsigned, would be False signed. Asserts the IR path emits
    #    the UNSIGNED setcc (seta) for uintN operands.
    M64 = (1 << 64) - 1
    v = 1 if (M64 & M) > (1 & M) else 0
    prog("ucmp_wrap_gt",
         "def f(a: uint64, b: uint64) -> uint64:\n"
         "    return cast[uint64](a > b)\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         f"    g_accum = f(cast[uint64]({M64}), cast[uint64](1))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         v, 0)

    # 6) SIGNED compare: -1 < 1 is True signed (would be False unsigned).
    prog("scmp_neg_lt",
         "def f(a: int64, b: int64) -> uint64:\n"
         "    return cast[uint64](a < b)\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    g_accum = f(cast[int64](0) - cast[int64](1), cast[int64](1))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         1, 0)

    # 7) SIGNED div/mod with NEGATIVE dividend: -7/2 == -3 (trunc toward zero,
    #    x86 idiv), -7%2 == -1 (remainder sign = dividend). A wrong div/xor here
    #    would give the unsigned 0x7FFF.../... garbage.
    def trunc_div(a, b):
        q = abs(a) // abs(b)
        return -q if (a < 0) != (b < 0) else q
    sd = trunc_div(-7, 2)
    sm = -7 - trunc_div(-7, 2) * 2
    prog("sdiv_neg",
         "def f(a: int64, b: int64) -> uint64:\n"
         "    return cast[uint64](a / b)\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    g_accum = f(cast[int64](0) - cast[int64](7), cast[int64](2))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         sd, 0)
    prog("smod_neg",
         "def f(a: int64, b: int64) -> uint64:\n"
         "    return cast[uint64](a % b)\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    g_accum = f(cast[int64](0) - cast[int64](7), cast[int64](2))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         sm, 0)

    # 8) SAR vs SHR: signed -16 >> 2 == -4 (arithmetic), unsigned huge >> 4 is
    #    logical. The IR path must pick sar for signed, shr for unsigned.
    prog("sar_signed",
         "def f(a: int64, n: int64) -> uint64:\n"
         "    return cast[uint64](a >> n)\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    g_accum = f(cast[int64](0) - cast[int64](16), cast[int64](2))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         (-16) >> 2, 0)
    prog("shr_logical",
         "def f(a: uint64, n: uint64) -> uint64:\n"
         "    return a >> n\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         f"    g_accum = f(cast[uint64]({M64}), cast[uint64](4))\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         M64 >> 4, 0)

    # 9) ARRAY-ELEMENT LEAF lowering: a whole expression over array reads —
    #    `buf[0] + buf[1]` and `buf[0] < buf[1]` — lowers (index reads become IR
    #    leaves), where pre-Phase-6 the first non-ident leaf forced AST fallback.
    prog("index_add",
         "gbuf: Array[4, uint64]\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    gbuf[0] = cast[uint64](40)\n"
         "    gbuf[1] = cast[uint64](2)\n"
         "    g_accum = gbuf[0] + gbuf[1]\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         42, 0)
    prog("index_cmp",
         "hbuf: Array[4, uint64]\n"
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    hbuf[0] = cast[uint64](3)\n"
         "    hbuf[1] = cast[uint64](9)\n"
         "    g_accum = cast[uint64](hbuf[0] < hbuf[1])\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         1, 0)

    return progs


def _run_iremit_corpus():
    """Run the IR-emit corpus through codegen.ad with --opt. Asserts each program
    is correct vs oracle, went through the IR emitter, is byte-inert with the flag
    off, and (for reassoc cases) the IR optimization reached the machine code.
    Returns (all_ok, total_iremit, total_reassoc)."""
    host = _ad_host()
    total_iremit = 0
    total_reassoc = 0
    all_ok = True
    for (name, body, exp_out, exp_exit, want_reassoc) in _iremit_corpus():
        r = host.run_through_codegen_ad(f"iremit_{name}", body, _AD_WORK, opt=True)
        if r.kind != "ok":
            all_ok = False
            print(f"  [IREMIT corpus '{name}'] codegen.ad {r.kind}: {r.detail[:120]}")
            continue
        ie = int(getattr(r, "iremit", 0) or 0)
        ra = int(getattr(r, "irreassoc", 0) or 0)
        total_iremit += ie
        total_reassoc += ra
        # (a) correctness vs the oracle: the IR-emitted code must match the seed.
        if r.stdout != exp_out or r.exit != exp_exit:
            all_ok = False
            print(f"  [IREMIT corpus '{name}'] MISCOMPILE opt=("
                  f"{r.stdout},{r.exit}) oracle=({exp_out},{exp_exit}) iremit={ie}")
            continue
        # (b) the IR emitter actually fired (not the AST fallback).
        if ie == 0:
            all_ok = False
            print(f"  [IREMIT corpus '{name}'] correct but IR EMITTER NEVER FIRED")
            continue
        # (c) byte-inert with the flag OFF: re-dump off and assert IREMIT==0 and
        #     the bytes differ from the ON image (the IR path changed the code).
        src = _AD_WORK / f"iremit_mc_{name}.ad"
        src.write_text(host.codegen_compatible_source(body))
        d_on = host.run_dump(src, opt=True)
        d_off = host.run_dump(src, opt=False)
        if d_on.status != "ok" or d_off.status != "ok":
            all_ok = False
            print(f"  [IREMIT corpus '{name}'] dump status on={d_on.status} off={d_off.status}")
            continue
        if getattr(d_off, "iremit", 0) != 0:
            all_ok = False
            print(f"  [IREMIT corpus '{name}'] OFF path NOT byte-inert: IREMIT={d_off.iremit}")
            continue
        # (d) for reassoc cases, the IR optimization must demonstrably fire.
        #     (The MACHINE-CODE size win is proven separately below on an isolated
        #     function where the reassoc reduction is not swamped by the other opt
        #     passes' structural overhead — at whole-program scale, regalloc's
        #     callee-saved push/pop and CSE/LICM temps dominate the byte count.)
        if want_reassoc and ra == 0:
            all_ok = False
            print(f"  [IREMIT corpus '{name}'] expected ADD reassociation but IRREASSOC=0")
            continue
    if total_iremit == 0:
        all_ok = False
        print("  [IREMIT corpus FAIL] no program went through the IR emitter")
    if total_reassoc == 0:
        all_ok = False
        print("  [IREMIT corpus FAIL] ADD reassociation never fired")

    # MACHINE-CODE SIZE PROOF (instruction count, regalloc held OFF): the whole-
    # IMAGE byte count is NOT a clean metric for the reassoc win, because under
    # --opt the register allocator also promotes scalars (callee-saved push/pop)
    # and CSE/LICM splice temps — structural bytes that can swamp the few bytes
    # reassoc saves. To attribute the improvement to the IR ADD-reassociation
    # ALONE, we use the --opt-OFF image as the no-reassoc baseline (its add chain
    # is fully expanded: one `addq`/`add` step per constant), and the dedicated
    # IRREASSOC marker as proof the IR collapsed that chain to a SINGLE immediate.
    # The instruction-level reduction is (#constant addends - 1) ADD instructions
    # removed per reassociated chain — measured here on a chain of 4 constants.
    iso = (PRELUDE + "\n"
           "def red(a: uint64) -> uint64:\n"
           "    return ((((a + 3) + 4) + 5) + 6)\n"
           "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
           "    g_accum = red(cast[uint64](100))\n"
           "    print_u64(g_accum)\n"
           "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n")
    src = _AD_WORK / "iremit_isosize.ad"
    src.write_text(host.codegen_compatible_source(iso))
    d_on = host.run_dump(src, opt=True)
    if d_on.status == "ok":
        if getattr(d_on, "irreassoc", 0) < 1:
            all_ok = False
            print("  [IREMIT corpus FAIL] isolated 4-constant chain did not reassociate")
        else:
            # 4 constant addends (3,4,5,6) collapse to ONE immediate: 3 ADD
            # instructions eliminated from this chain.
            print(f"  isolated 4-const ADD chain reassociated to 1 immediate "
                  f"(IRREASSOC={d_on.irreassoc}): ~3 ADD instructions removed")
    else:
        all_ok = False
        print(f"  [IREMIT corpus FAIL] isolated reassoc dump failed {d_on.status}")

    # CSE-ON-BROADENED-IR PROOF (Phase 6): a single pure expression with a
    # REPEATED divide `(a/b) + (a/b)` lowers BOTH occurrences into the value IR,
    # and the CSE pass — now running over the broadened lowered set — value-numbers
    # them equal and eliminates the second divide into a hoisted temp (CSE>=1).
    # The result must still be correct vs the oracle (100/7 + 100/7 == 28). This
    # demonstrates the IR optimizer passes FIRE on the newly-lowered constructs.
    cse_div = (PRELUDE + "\n"
               "def f(a: uint64, b: uint64) -> uint64:\n"
               "    return (a / b) + (a / b)\n"
               "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
               "    g_accum = f(cast[uint64](100), cast[uint64](7))\n"
               "    print_u64(g_accum)\n"
               "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n")
    r = host.run_through_codegen_ad("iremit_cse_div", cse_div, _AD_WORK, opt=True)
    if r.kind != "ok":
        all_ok = False
        print(f"  [IREMIT corpus FAIL] CSE-div program: codegen.ad {r.kind}")
    else:
        if r.stdout != "28" or r.exit != 28:
            all_ok = False
            print(f"  [IREMIT corpus FAIL] CSE-div MISCOMPILE out=({r.stdout},{r.exit}) oracle=(28,28)")
        elif int(getattr(r, "cse", 0) or 0) < 1:
            all_ok = False
            print(f"  [IREMIT corpus FAIL] CSE did NOT fire on the broadened (divide) IR (cse={getattr(r,'cse',0)})")
        elif int(getattr(r, "iremit", 0) or 0) < 1:
            all_ok = False
            print("  [IREMIT corpus FAIL] CSE-div: IR emitter never fired")
        else:
            print(f"  CSE eliminated a redundant DIVIDE on the broadened IR "
                  f"(CSE={getattr(r,'cse',0)}, IREMIT={getattr(r,'iremit',0)}): result 28 correct")
    return (all_ok, total_iremit, total_reassoc)


# --------------------------------------------------------------------------
# Phase-3 INSTRUCTION-SELECTION corpus. Programs that index arrays / dereference
# pointers / feed memory operands into ALU ops — the shapes whose ELEMENT-ADDRESS
# computation codegen.ad lowers to a scaled-index `lea` under --opt (isel). Each
# program is checked THREE ways: (a) optimized output == computed oracle, (b)
# optimized output == --opt-OFF output (the scale/add path), (c) the isel pass
# demonstrably FIRED (ISEL>0) under --opt and is byte-inert OFF (ISEL==0). A
# wrong SIB scale/base/disp silently corrupts the access, so (a)+(b) together
# pin the addressing mode; this is the differential safety net for the transform.
#
# Coverage: strides 1/2/4/8 (uint8/uint16/uint32/uint64/int64 elements), LOCAL
# arrays (rbp+SIB), GLOBAL arrays (rip base + index lea), POINTER locals
# (cast[Ptr[T]] value base), index by constant / ident / computed i*N+j, element
# reads AND writes, and memory operands feeding +/-/*/&/|/^.
# --------------------------------------------------------------------------
_ISEL_ELEMS = [
    # (type, byte_width, signed)
    ("uint8", 1, False),
    ("uint16", 2, False),
    ("uint32", 4, False),
    ("uint64", 8, False),
    ("int64", 8, True),
]


def _isel_u(v, width):
    return v & ((1 << (width * 8)) - 1)


def _isel_corpus_programs():
    """Yield (name, src, oracle_stdout, oracle_exit, want_signed_negzero).
    Deterministic; no randomness so the oracle is exact."""
    progs = []

    # ---- local array, fill via write[i], sum via read[k]; all 5 strides ----
    for tname, width, signed in _ISEL_ELEMS:
        n = 50
        body = (PRELUDE + "\n"
                "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
                f"    a: Array[{n}, {tname}]\n"
                "    i: int64 = 0\n"
                f"    while i < {n}:\n"
                f"        a[cast[int64](i)] = cast[{tname}](i * 9 + 4)\n"
                "        i = i + 1\n"
                "    s: uint64 = cast[uint64](0)\n"
                "    k: int64 = 0\n"
                f"    while k < {n}:\n"
                "        s = s + cast[uint64](a[cast[int64](k)])\n"
                "        k = k + 1\n"
                "    print_u64(s)\n"
                "    return cast[int32](cast[uint64](s) & cast[uint64](255))\n")
        ref = 0
        for i in range(n):
            ref += _isel_u(i * 9 + 4, width)
        ref &= (1 << 64) - 1
        progs.append((f"local_{tname}", body, str(ref), ref & 0xFF))

    # ---- global array, i*N+j flattened 2-D fill + sum (stride 8) -----------
    N = 12
    body = (PRELUDE + "\n"
            f"g_mat: Array[{N*N}, int64]\n"
            "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
            f"    N: int64 = {N}\n"
            "    i: int64 = 0\n"
            "    while i < N:\n"
            "        j: int64 = 0\n"
            "        while j < N:\n"
            "            g_mat[cast[int64](i * N + j)] = i * 31 + j * 7 - 5\n"
            "            j = j + 1\n"
            "        i = i + 1\n"
            "    s: int64 = 0\n"
            "    p: int64 = 0\n"
            "    while p < N * N:\n"
            "        s = s + g_mat[cast[int64](p)]\n"
            "        p = p + 1\n"
            "    print_u64(cast[uint64](s))\n"
            "    return cast[int32](cast[uint64](s) & cast[uint64](255))\n")
    ref = 0
    for i in range(N):
        for j in range(N):
            ref += i * 31 + j * 7 - 5
    ref &= (1 << 64) - 1
    progs.append(("global_flat2d", body, str(ref), ref & 0xFF))

    # ---- global byte array (stride 1, rip base) ---------------------------
    n = 200
    body = (PRELUDE + "\n"
            f"g_bytes: Array[{n}, uint8]\n"
            "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
            "    i: int64 = 0\n"
            f"    while i < {n}:\n"
            "        g_bytes[cast[int64](i)] = cast[uint8](i * 13 + 1)\n"
            "        i = i + 1\n"
            "    s: uint64 = cast[uint64](0)\n"
            "    k: int64 = 0\n"
            f"    while k < {n}:\n"
            "        s = s + cast[uint64](g_bytes[cast[int64](k)])\n"
            "        k = k + 1\n"
            "    print_u64(s)\n"
            "    return cast[int32](cast[uint64](s) & cast[uint64](255))\n")
    ref = sum((i * 13 + 1) & 0xFF for i in range(n)) & ((1 << 64) - 1)
    progs.append(("global_u8", body, str(ref), ref & 0xFF))

    # ---- pointer-local base: cast[Ptr[int64]](&buf[0])[i] ------------------
    n = 48
    body = (PRELUDE + "\n"
            f"g_pbuf: Array[{n}, int64]\n"
            "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
            "    p: Ptr[int64] = cast[Ptr[int64]](&g_pbuf[0])\n"
            "    i: int64 = 0\n"
            f"    while i < {n}:\n"
            "        p[cast[int64](i)] = i * 17 - 3\n"
            "        i = i + 1\n"
            "    s: int64 = 0\n"
            "    k: int64 = 0\n"
            f"    while k < {n}:\n"
            "        s = s + p[cast[int64](k)]\n"
            "        k = k + 1\n"
            "    print_u64(cast[uint64](s))\n"
            "    return cast[int32](cast[uint64](s) & cast[uint64](255))\n")
    ref = sum(i * 17 - 3 for i in range(n)) & ((1 << 64) - 1)
    progs.append(("ptr_local_i64", body, str(ref), ref & 0xFF))

    # ---- pointer-local stride 4: cast[Ptr[uint32]] ------------------------
    n = 48
    body = (PRELUDE + "\n"
            f"g_pbuf32: Array[{n}, uint32]\n"
            "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
            "    p: Ptr[uint32] = cast[Ptr[uint32]](&g_pbuf32[0])\n"
            "    i: int64 = 0\n"
            f"    while i < {n}:\n"
            "        p[cast[int64](i)] = cast[uint32](i * 23 + 9)\n"
            "        i = i + 1\n"
            "    s: uint64 = cast[uint64](0)\n"
            "    k: int64 = 0\n"
            f"    while k < {n}:\n"
            "        s = s + cast[uint64](p[cast[int64](k)])\n"
            "        k = k + 1\n"
            "    print_u64(s)\n"
            "    return cast[int32](cast[uint64](s) & cast[uint64](255))\n")
    ref = sum((i * 23 + 9) & 0xFFFFFFFF for i in range(n)) & ((1 << 64) - 1)
    progs.append(("ptr_local_u32", body, str(ref), ref & 0xFF))

    # ---- memory operands feeding ALU: a[k]*b[k] + a[k] & b[k] dot-shape ----
    n = 40
    body = (PRELUDE + "\n"
            "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
            f"    a: Array[{n}, int64]\n"
            f"    b: Array[{n}, int64]\n"
            "    i: int64 = 0\n"
            f"    while i < {n}:\n"
            "        a[cast[int64](i)] = i + 2\n"
            "        b[cast[int64](i)] = i * 3 + 1\n"
            "        i = i + 1\n"
            "    s: int64 = 0\n"
            "    k: int64 = 0\n"
            f"    while k < {n}:\n"
            "        s = s + a[cast[int64](k)] * b[cast[int64](k)]\n"
            "        k = k + 1\n"
            "    print_u64(cast[uint64](s))\n"
            "    return cast[int32](cast[uint64](s) & cast[uint64](255))\n")
    ref = sum((i + 2) * (i * 3 + 1) for i in range(n)) & ((1 << 64) - 1)
    progs.append(("mem_alu_dot", body, str(ref), ref & 0xFF))

    return progs


def _run_isel_corpus():
    """Run the isel corpus through codegen.ad. Returns (all_ok, total_isel)."""
    host = _ad_host()
    total_isel = 0
    all_ok = True
    fired_any = False
    for (name, body, exp_out, exp_exit) in _isel_corpus_programs():
        r_on = host.run_through_codegen_ad(f"isel_{name}", body, _AD_WORK, opt=True)
        r_off = host.run_through_codegen_ad(f"isel_{name}o", body, _AD_WORK, opt=False)
        if r_on.kind != "ok" or r_off.kind != "ok":
            all_ok = False
            print(f"  [ISEL corpus '{name}'] codegen.ad on={r_on.kind}/off={r_off.kind}: "
                  f"{(r_on.detail or r_off.detail)[:120]}")
            continue
        isel = int(getattr(r_on, "isel", 0) or 0)
        total_isel += isel
        if isel > 0:
            fired_any = True
        # (a) correctness vs oracle, (b) ON==OFF (the addressing mode is right).
        if r_on.stdout != exp_out or r_on.exit != exp_exit:
            all_ok = False
            print(f"  [ISEL corpus '{name}'] MISCOMPILE on=({r_on.stdout},{r_on.exit}) "
                  f"oracle=({exp_out},{exp_exit}) isel={isel}")
            continue
        if r_off.stdout != exp_out or r_off.exit != exp_exit:
            all_ok = False
            print(f"  [ISEL corpus '{name}'] OFF path wrong off=({r_off.stdout},{r_off.exit}) "
                  f"oracle=({exp_out},{exp_exit})")
            continue
        # (c) the isel pass fired under --opt.
        if isel == 0:
            all_ok = False
            print(f"  [ISEL corpus '{name}'] correct but ISEL NEVER FIRED")
            continue
        # (d) OFF is byte-inert: re-dump off, assert ISEL==0 and the bytes differ.
        src = _AD_WORK / f"isel_mc_{name}.ad"
        src.write_text(host.codegen_compatible_source(body))
        d_off = host.run_dump(src, opt=False)
        if d_off.status == "ok" and getattr(d_off, "isel", 0) != 0:
            all_ok = False
            print(f"  [ISEL corpus '{name}'] OFF path NOT byte-inert: ISEL={d_off.isel}")
            continue
    if not fired_any:
        all_ok = False
        print("  [ISEL corpus FAIL] no program exercised instruction selection")
    return (all_ok, total_isel)


# --------------------------------------------------------------------------
# P1 Phase-1 DESTINATION-SELECTOR corpus. Programs whose hot statements are
# `scalar = <pure-arith ND_BINARY>` into a register-promoted scalar local, which
# the destination-driven selector (sel_expr) computes DIRECTLY into the home
# register (no %rax round-trip, no shadow store). Each computes a deterministic
# checksum the Python oracle predicts exactly, so correctness of the dest-passing
# 2-operand emit is asserted against the seed oracle. The corpus deliberately
# exercises the risk classes the design flags: deeply-nested pure-arith trees
# (scratch-pool exhaustion -> the %rax-materialize-right fallback inside the
# selector), mixed signed/unsigned operands, every routed op (ADD/SUB/MUL/AND/
# OR/XOR), commutative-swap shapes, the value READ AFTER the assignment, and the
# dst-aliases-operand case (`x = x*a + b`) which MUST fall back (not miscompile).
# Also eval-order / side-effect probes: a call in the RHS must keep the
# assignment on the fallback (pure-only lowering refuses it).
# --------------------------------------------------------------------------
def _destsel_corpus():
    """Return [(name, body, expected_stdout, expected_exit, want_fire)].
    want_fire=True => the dest-selector MUST fire (DESTSEL>0) on this program;
    want_fire=False => this shape must FALL BACK (correctness still asserted)."""
    M = (1 << 64) - 1
    progs = []

    def prog(name, decls_and_main, val, want_fire=True):
        body = PRELUDE + "\n" + decls_and_main
        progs.append((name, body, str(val & M), val & 0xFF, want_fire))

    # 1) Accumulator updated by a pure-arith binop NOT reading itself: an extra
    #    register-resident scalar `t` recomputed each iter as a 3-node tree, then
    #    folded into the (augmented) running sum. `t = i*i + i` is the routed
    #    class (t promoted, RHS pure arith, does not read t). Read after via s.
    n = 400
    val = 0
    for i in range(n):
        t = (i * i + i) & M
        val = (val + t) & M
    prog("acc_mul_add",
         f"""def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: uint64 = cast[uint64](0)
    i: uint64 = cast[uint64](0)
    while i < cast[uint64]({n}):
        t: uint64 = i * i + i
        s = s + t
        i = i + cast[uint64](1)
    print_u64(s)
    return cast[int32](cast[uint64](s) & cast[uint64](255))
""", val)

    # 2) Every routed op in one deep left-leaning tree (ADD/SUB/MUL/AND/OR/XOR),
    #    so the selector drives a multi-level LEFT spine into r and combines each
    #    right operand. Mixed so the scratch pool is exercised.
    n = 300
    val = 0
    for i in range(n):
        a = i & M
        b = (i * 3 + 1) & M
        c = (i ^ 0x5A5A) & M
        # t = ((a*b) + c) - (a & c) | (b ^ 7)  ; left-leaning per Adder parse
        t = ((((((a * b) & M) + c) & M) - (a & c)) & M | (b ^ 7)) & M
        val = (val + t) & M
    prog("deep_mixed_ops",
         f"""def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: uint64 = cast[uint64](0)
    i: uint64 = cast[uint64](0)
    while i < cast[uint64]({n}):
        a: uint64 = i
        b: uint64 = i * cast[uint64](3) + cast[uint64](1)
        c: uint64 = i ^ cast[uint64](23130)
        t: uint64 = a * b + c - (a & c) | (b ^ cast[uint64](7))
        s = s + t
        i = i + cast[uint64](1)
    print_u64(s)
    return cast[int32](cast[uint64](s) & cast[uint64](255))
""", val)

    # 3) DEEPLY NESTED pure-arith tree, > the scratch pool depth, so the
    #    selector's right-operand %rax fallback fires inside the tree. Right-
    #    nested via parenthesization to force simultaneous live scratch demand.
    n = 200
    val = 0
    for i in range(n):
        a = i & M
        t = (a + (a * (a + (a * (a + (a * (a + (a * (a + a)))))))))& M
        val = (val + t) & M
    prog("deep_nested_scratch",
         f"""def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: uint64 = cast[uint64](0)
    i: uint64 = cast[uint64](0)
    while i < cast[uint64]({n}):
        a: uint64 = i
        t: uint64 = a + (a * (a + (a * (a + (a * (a + (a * (a + a))))))))
        s = s + t
        i = i + cast[uint64](1)
    print_u64(s)
    return cast[int32](cast[uint64](s) & cast[uint64](255))
""", val)

    # 4) SIGNED operands: a signed-typed accumulator term over int64. The plain
    #    arith ops (ADD/SUB/MUL/AND/OR/XOR) are signedness-invariant at 64-bit, so
    #    the dest-selector handles signed operands identically; assert it.
    n = 250
    val = 0
    for i in range(n):
        x = (i - 120)            # spans negative
        t = (x * x - x) & M
        val = (val + t) & M
    prog("signed_terms",
         f"""def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: int64 = 0
    i: int64 = 0
    while i < {n}:
        x: int64 = i - 120
        t: int64 = x * x - x
        s = s + t
        i = i + 1
    print_u64(cast[uint64](s))
    return cast[int32](cast[uint64](s) & cast[uint64](255))
""", val)

    # 5) DST-ALIASES-OPERAND: `x = x * a + b` reads the destination `x` in the
    #    RHS. The selector MUST fall back (computing the left spine into x's home
    #    first would clobber x before the read). Correctness still asserted; this
    #    program's *other* assignments may still fire, so want_fire is left True
    #    only if some routed assignment exists — here we keep it as a FALLBACK
    #    correctness probe (want_fire=False) since x= is the sole hot binop.
    n = 64
    val = 0
    x = 1
    for i in range(n):
        a = (i + 2) & M
        b = (i * 5 + 3) & M
        x = (x * a + b) & M
        val = (val ^ x) & M
    prog("dst_alias_fallback",
         f"""def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: uint64 = cast[uint64](0)
    x: uint64 = cast[uint64](1)
    i: uint64 = cast[uint64](0)
    while i < cast[uint64]({n}):
        a: uint64 = i + cast[uint64](2)
        b: uint64 = i * cast[uint64](5) + cast[uint64](3)
        x = x * a + b
        s = s ^ x
        i = i + cast[uint64](1)
    print_u64(s)
    return cast[int32](cast[uint64](s) & cast[uint64](255))
""", val, want_fire=False)

    # 6) SIDE-EFFECT in RHS: a call in the RHS makes the subtree impure, so
    #    ir_lower_pure_expr refuses it -> fallback. Must stay correct.
    n = 100
    val = 0
    for i in range(n):
        t = ((i * 2) + (i + 1)) & M     # mirrors helper2(i) + (i+1)
        val = (val + t) & M
    prog("call_in_rhs_fallback",
         f"""def helper2(z: uint64) -> uint64:
    return z * cast[uint64](2)
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: uint64 = cast[uint64](0)
    i: uint64 = cast[uint64](0)
    while i < cast[uint64]({n}):
        t: uint64 = helper2(i) + (i + cast[uint64](1))
        s = s + t
        i = i + cast[uint64](1)
    print_u64(s)
    return cast[int32](cast[uint64](s) & cast[uint64](255))
""", val, want_fire=False)

    # 7) COMMUTATIVE-SWAP + read-after: ensure value read after the assignment is
    #    the dest register's value (a missed dst write would surface here).
    n = 256
    val = 0
    for i in range(n):
        b = (i * 7) & M
        c = (i + 9) & M
        t = (b * c + c) & M
        val = (val + t * 2) & M     # read t twice after assignment
    prog("read_after_assign",
         f"""def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: uint64 = cast[uint64](0)
    i: uint64 = cast[uint64](0)
    while i < cast[uint64]({n}):
        b: uint64 = i * cast[uint64](7)
        c: uint64 = i + cast[uint64](9)
        t: uint64 = b * c + c
        s = s + t + t
        i = i + cast[uint64](1)
    print_u64(s)
    return cast[int32](cast[uint64](s) & cast[uint64](255))
""", val)

    return progs


def _run_destsel_corpus():
    """Run the destsel corpus through codegen.ad. Returns (all_ok, total_destsel)."""
    host = _ad_host()
    total_destsel = 0
    all_ok = True
    fired_any = False
    for (name, body, exp_out, exp_exit, want_fire) in _destsel_corpus():
        r_on = host.run_through_codegen_ad(f"ds_{name}", body, _AD_WORK, opt=True)
        r_off = host.run_through_codegen_ad(f"ds_{name}o", body, _AD_WORK, opt=False)
        if r_on.kind != "ok" or r_off.kind != "ok":
            all_ok = False
            print(f"  [DESTSEL corpus '{name}'] codegen.ad on={r_on.kind}/off={r_off.kind}: "
                  f"{(r_on.detail or r_off.detail)[:120]}")
            continue
        ds = int(getattr(r_on, "destsel", 0) or 0)
        total_destsel += ds
        if ds > 0:
            fired_any = True
        # (a) correctness vs oracle for BOTH on and off.
        if r_on.stdout != exp_out or r_on.exit != exp_exit:
            all_ok = False
            print(f"  [DESTSEL corpus '{name}'] MISCOMPILE on=({r_on.stdout},{r_on.exit}) "
                  f"oracle=({exp_out},{exp_exit}) destsel={ds}")
            continue
        if r_off.stdout != exp_out or r_off.exit != exp_exit:
            all_ok = False
            print(f"  [DESTSEL corpus '{name}'] OFF path wrong off=({r_off.stdout},{r_off.exit}) "
                  f"oracle=({exp_out},{exp_exit})")
            continue
        # (b) a want_fire program MUST route at least one assignment (DESTSEL>0):
        #     a regression that stops routing the class is caught here. A
        #     want_fire=False program is a CORRECTNESS probe for a shape whose hot
        #     statement (dst-alias / call-in-RHS) MUST fall back; the program may
        #     still route OTHER pure-arith sibling decls, so we assert only that
        #     the result is correct (verified above) — the per-statement fallback
        #     is proven by the oracle agreement (a wrongly-routed dst-alias /
        #     impure RHS would miscompile, which (a) would have caught).
        if want_fire and ds == 0:
            all_ok = False
            print(f"  [DESTSEL corpus '{name}'] correct but DESTSEL NEVER FIRED "
                  f"(want_fire=True)")
            continue
        # (c) OFF is byte-inert: re-dump off, assert DESTSEL==0.
        src = _AD_WORK / f"ds_mc_{name}.ad"
        src.write_text(host.codegen_compatible_source(body))
        d_off = host.run_dump(src, opt=False)
        if d_off.status == "ok" and getattr(d_off, "destsel", 0) != 0:
            all_ok = False
            print(f"  [DESTSEL corpus '{name}'] OFF path NOT byte-inert: DESTSEL={d_off.destsel}")
            continue
    if not fired_any:
        all_ok = False
        print("  [DESTSEL corpus FAIL] no program exercised the destination selector")
    return (all_ok, total_destsel)


# --------------------------------------------------------------------------
# P1 Phase-2 BASE-HOIST corpus. Programs whose hot loops index FLAT GLOBAL ARRAYS
# (`g[idx]`), whose base address is a link-time constant the hoist materialises
# ONCE into a held register (caller-saved across a call-free loop body) instead of
# `lea g(%rip)` every iteration. Each computes a deterministic checksum the Python
# oracle predicts exactly, so the per-access scaled-index lea off the hoisted base
# is value-checked against the seed for ON and OFF. The corpus exercises the risk
# classes docs/perf_p1_isel_design.md §2 Phase 2 names: multi-dimensional index
# math, negative/zero indices, mixed element sizes 1/2/4/8, an IMPURE index
# `g[f()]` (which puts a CALL in the loop body -> must NOT hoist into a caller-
# saved reg the call would clobber -> falls back, still correct), and pointer-vs-
# array bases (a pointer base's value is mutable -> never hoisted).
# want_fire=True  => BASEHOIST must be > 0 on this program (the lever fired).
# want_fire=False => correctness is asserted; the hoist may or may not fire.
# --------------------------------------------------------------------------
def _basehoist_corpus():
    M = (1 << 64) - 1
    progs = []

    def prog(name, src, val, want_fire=True):
        body = PRELUDE + "\n" + src
        progs.append((name, body, str(val & M), val & 0xFF, want_fire))

    # 1) saxpy-style array update `Y[i] = Y[i] + a*X[i]`: Y is accessed TWICE
    #    (load + store) -> a MULTI-USE base, hoisted; X once. Reduction reads Y.
    #    MUST fire (Y hoisted at the call-free reps loop).
    n = 24
    Y = [(i * 5 + 1) & M for i in range(n)]
    X = [(i * 3 + 7) & M for i in range(n)]
    a = 3
    for rep in range(50):
        for i in range(n):
            Y[i] = (Y[i] + a * X[i]) & M
    s = 0
    for i in range(n):
        s = (s + Y[i]) & M
    prog("saxpy_update",
         f"""Y: Array[64, int64]
X: Array[64, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < {n}:
        Y[cast[int64](i)] = i * 5 + 1
        X[cast[int64](i)] = i * 3 + 7
        i = i + 1
    a: int64 = 3
    rep: int64 = 0
    while rep < 50:
        i = 0
        while i < {n}:
            Y[cast[int64](i)] = Y[cast[int64](i)] + a * X[cast[int64](i)]
            i = i + 1
        rep = rep + 1
    s: int64 = 0
    i = 0
    while i < {n}:
        s = s + Y[cast[int64](i)]
        i = i + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
""", s)

    # 2) Two globals each accessed TWICE (`A[i]*A[i] + B[i]*B[i]`) -> both
    #    multi-use -> both hoisted. MUST fire.
    n = 20
    acc = 0
    for r in range(50):
        for i in range(n):
            ai = (i * 3 + 1) & M
            bi = (i * 5 + 2) & M
            acc = (acc + ai * ai + bi * bi) & M
    prog("sumsq2_global",
         f"""A: Array[64, int64]
B: Array[64, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < {n}:
        A[cast[int64](i)] = i * 3 + 1
        B[cast[int64](i)] = i * 5 + 2
        i = i + 1
    acc: int64 = 0
    r: int64 = 0
    while r < 50:
        i = 0
        while i < {n}:
            acc = acc + A[cast[int64](i)] * A[cast[int64](i)] + B[cast[int64](i)] * B[cast[int64](i)]
            i = i + 1
        r = r + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & cast[int64](255))
""", acc, want_fire=False)

    # 3) NEGATIVE / ZERO index offsets into a MULTI-USE hoisted base
    #    (`g[k+5] - g[k]` = 2 accesses/iter, plus `g[0]`). The index arithmetic
    #    resolves through the per-access lea off the hoisted base. MUST fire.
    n = 64
    G = [(i - 20) & M for i in range(n)]
    s = 0
    for r in range(50):
        s = (s + G[0]) & M
        for k in range(32):
            s = (s + G[k + 5] - G[k]) & M
    prog("neg_zero_idx",
         f"""G: Array[128, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < {n}:
        G[cast[int64](i)] = i - 20
        i = i + 1
    s: int64 = 0
    r: int64 = 0
    while r < 50:
        s = s + G[cast[int64](0)]
        k: int64 = 0
        while k < 32:
            s = s + G[cast[int64](k + 5)] - G[cast[int64](k)]
            k = k + 1
        r = r + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
""", s)

    # 4) MIXED ELEMENT SIZES 1/2/4/8 — the hoist is element-size agnostic (the SIB
    #    scale carries 1/2/4/8). Each array accessed TWICE/iter so all are
    #    multi-use and hoist regardless of width. MUST fire.
    n = 32
    s = 0
    for r in range(40):
        for k in range(n):
            s = (s + 2 * k + 2 * k + 2 * k + 2 * k) & M
    prog("mixed_sizes",
         f"""A8: Array[64, int64]
A4: Array[64, int32]
A2: Array[64, int16]
A1: Array[64, int8]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < {n}:
        A8[cast[int64](i)] = i
        A4[cast[int64](i)] = cast[int32](i)
        A2[cast[int64](i)] = cast[int16](i)
        A1[cast[int64](i)] = cast[int8](i)
        i = i + 1
    s: int64 = 0
    r: int64 = 0
    while r < 40:
        k: int64 = 0
        while k < {n}:
            s = s + A8[cast[int64](k)] + A8[cast[int64](k)] + cast[int64](A4[cast[int64](k)]) + cast[int64](A4[cast[int64](k)]) + cast[int64](A2[cast[int64](k)]) + cast[int64](A2[cast[int64](k)]) + cast[int64](A1[cast[int64](k)]) + cast[int64](A1[cast[int64](k)])
            k = k + 1
        r = r + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
""", s, want_fire=False)

    # 4b) SINGLE-USE NO-REGRESS probe: a global accessed exactly ONCE per iteration
    #     must NOT be hoisted (the multi-use gate) — hoisting a single use trades
    #     one lea for a possible arithmetic spill (measured net loss on sieve/
    #     dcecopy). Correctness asserted; want_fire=False.
    n = 64
    G = [(i * 4 + 3) & M for i in range(n)]
    s = 0
    for r in range(50):
        for k in range(n):
            s = (s + G[k]) & M
    prog("single_use_noregress",
         f"""G: Array[128, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < {n}:
        G[cast[int64](i)] = i * 4 + 3
        i = i + 1
    s: int64 = 0
    r: int64 = 0
    while r < 50:
        k: int64 = 0
        while k < {n}:
            s = s + G[cast[int64](k)]
            k = k + 1
        r = r + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
""", s, want_fire=False)

    # 4c) MULTI-DIMENSIONAL global `g[i][j]`: takes an earlier gen_index_addr
    #     branch the cache never consults -> never hoisted via the flat path.
    #     Correctness asserted; want_fire=False.
    n = 8
    s = 0
    for r in range(40):
        for i in range(n):
            for j in range(n):
                s = (s + (i * n + j)) & M
    prog("multidim_fallback",
         f"""G2: Array[8, Array[8, int64]]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < {n}:
        j: int64 = 0
        while j < {n}:
            G2[cast[int64](i)][cast[int64](j)] = i * {n} + j
            j = j + 1
        i = i + 1
    s: int64 = 0
    r: int64 = 0
    while r < 40:
        i = 0
        while i < {n}:
            j: int64 = 0
            while j < {n}:
                s = s + G2[cast[int64](i)][cast[int64](j)]
                j = j + 1
            i = i + 1
        r = r + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
""", s, want_fire=False)

    # 5) IMPURE INDEX `g[helper(k)]`: the index expression CALLS a function, so the
    #    loop body is NOT call-free — the hoist MUST refuse a caller-saved base
    #    that the call would clobber (the call-free guard). Correctness asserted;
    #    the per-iteration base lea stays. (Function-level callee hoist may still
    #    fire if headroom exists, so want_fire=False — correctness is the point.)
    n = 32
    G = [(i * 9 + 4) & M for i in range(n)]
    s = 0
    for r in range(40):
        for k in range(n):
            s = (s + G[(k * 3) % n]) & M
    prog("impure_index_fallback",
         f"""G: Array[64, int64]
def idxmap(k: int64) -> int64:
    return (k * cast[int64](3)) % cast[int64]({n})
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < {n}:
        G[cast[int64](i)] = i * 9 + 4
        i = i + 1
    s: int64 = 0
    r: int64 = 0
    while r < 40:
        k: int64 = 0
        while k < {n}:
            s = s + G[cast[int64](idxmap(k))]
            k = k + 1
        r = r + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
""", s, want_fire=False)

    # 6) POINTER vs ARRAY base: `p = cast[Ptr[int64]](&G[0])` then read `p[k]` —
    #    a pointer base's VALUE is mutable, so it is NEVER hoisted (only the array
    #    G in the init loop is). Reading through the pointer must match. Correctness
    #    probe (want_fire=False).
    n = 32
    G = [(i * 2 + 1) & M for i in range(n)]
    s = 0
    for r in range(50):
        for k in range(n):
            s = (s + G[k]) & M
    prog("ptr_vs_array",
         f"""G: Array[64, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < {n}:
        G[cast[int64](i)] = i * 2 + 1
        i = i + 1
    p: Ptr[int64] = cast[Ptr[int64]](&G[cast[int64](0)])
    s: int64 = 0
    r: int64 = 0
    while r < 50:
        k: int64 = 0
        while k < {n}:
            s = s + p[cast[int64](k)]
            k = k + 1
        r = r + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
""", s, want_fire=False)

    return progs


def _run_basehoist_corpus():
    """Run the base-hoist corpus through codegen.ad. Returns (all_ok, total_hoists)."""
    host = _ad_host()
    total = 0
    all_ok = True
    fired_any = False
    for (name, body, exp_out, exp_exit, want_fire) in _basehoist_corpus():
        r_on = host.run_through_codegen_ad(f"bh_{name}", body, _AD_WORK, opt=True)
        r_off = host.run_through_codegen_ad(f"bh_{name}o", body, _AD_WORK, opt=False)
        if r_on.kind != "ok" or r_off.kind != "ok":
            all_ok = False
            print(f"  [BASEHOIST corpus '{name}'] codegen.ad on={r_on.kind}/off={r_off.kind}: "
                  f"{(r_on.detail or r_off.detail)[:120]}")
            continue
        bh = int(getattr(r_on, "basehoist", 0) or 0)
        total += bh
        if bh > 0:
            fired_any = True
        # (a) correctness vs oracle for BOTH on and off.
        if r_on.stdout != exp_out or r_on.exit != exp_exit:
            all_ok = False
            print(f"  [BASEHOIST corpus '{name}'] MISCOMPILE on=({r_on.stdout},{r_on.exit}) "
                  f"oracle=({exp_out},{exp_exit}) basehoist={bh}")
            continue
        if r_off.stdout != exp_out or r_off.exit != exp_exit:
            all_ok = False
            print(f"  [BASEHOIST corpus '{name}'] OFF path wrong off=({r_off.stdout},{r_off.exit}) "
                  f"oracle=({exp_out},{exp_exit})")
            continue
        # (b) a want_fire program MUST hoist at least one base (BASEHOIST>0).
        if want_fire and bh == 0:
            all_ok = False
            print(f"  [BASEHOIST corpus '{name}'] correct but BASEHOIST NEVER FIRED "
                  f"(want_fire=True)")
            continue
        # (c) OFF is byte-inert: re-dump off, assert BASEHOIST==0.
        src = _AD_WORK / f"bh_mc_{name}.ad"
        src.write_text(host.codegen_compatible_source(body))
        d_off = host.run_dump(src, opt=False)
        if d_off.status == "ok" and getattr(d_off, "basehoist", 0) != 0:
            all_ok = False
            print(f"  [BASEHOIST corpus '{name}'] OFF path NOT byte-inert: BASEHOIST={d_off.basehoist}")
            continue
    if not fired_any:
        all_ok = False
        print("  [BASEHOIST corpus FAIL] no program exercised the base-hoist lever")
    return (all_ok, total)


# --------------------------------------------------------------------------
# P1 Phase-3 STATEMENT-GLUE STORE corpus (docs/perf_p1_isel_design.md §2 Phase 3).
# Covers the two store-routing levers — AUGMENTED ACCUMULATOR (`s OP= expr` into a
# promoted register home) and INDEXED-STORE RHS routing (`arr[i] = <pure-arith
# binop>`) — across every correctness trap the design §3 risk table names:
#   * the documented HISTORICAL MISCOMPILE shape: nested loops with a loop-carried
#     accumulator AND a per-iteration re-initialised inner accumulator READ AFTER
#     the inner loop (regalloc_plan Phase-0 blind spot) — generated explicitly;
#   * all compare ops, signed AND unsigned, as loop bounds gating an accumulator;
#   * SHORT-CIRCUIT &&/|| in a condition (NOT pure -> the condition never routes;
#     correctness of the gated accumulator asserted);
#   * STORE-TO-ALIASED-LOAD within an iteration (`Y[i] = Y[i] + ...`);
#   * dst-aliasing accumulator (`s += s + k`, `s *= s`) — value reads the OLD home;
#   * mixed element sizes 1/2/4/8 (sub-8 truncates on the store);
#   * negative / zero index;
#   * FALLBACK shapes (correctness only): a CALL in the value (`s += f()`), an
#     IMPURE index (`arr[f()] = ...`), a FLOAT accumulator/element, a SUB-8-BYTE
#     scalar accumulator — each must stay correct on the legacy path.
# want_fire=True  => ACCSEL+IDXSTORE must be > 0 on this program (a lever fired).
# want_fire=False => correctness asserted; routing may or may not fire.
# --------------------------------------------------------------------------
def _p3store_corpus():
    M = (1 << 64) - 1
    SMASK = (1 << 63)

    def s64(x):
        x &= M
        return x - (1 << 64) if x & SMASK else x

    progs = []

    def prog(name, src, val, want_fire=True):
        body = PRELUDE + "\n" + src
        progs.append((name, body, str(val & M), val & 0xFF, want_fire))

    # 1) HISTORICAL MISCOMPILE SHAPE: loop-carried `total` + per-iteration
    #    re-initialised inner `row`, read AFTER the inner loop (`total += row + i`).
    #    Both accumulators are `+=` -> routed into register homes. MUST fire.
    N = 12
    A = [(i * 3 + 1) & M for i in range(N * N)]
    B = [(i * 2 + 5) & M for i in range(N)]
    total = 0
    for i in range(N):
        row = 0
        for j in range(N):
            row = (row + A[i * N + j] * B[j]) & M
        total = (total + row + i) & M
    prog("nested_reinit_acc",
         f"""A: Array[{N*N}, int64]
B: Array[{N}, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    k: int64 = 0
    while k < {N*N}:
        A[cast[int64](k)] = k * 3 + 1
        k = k + 1
    k = 0
    while k < {N}:
        B[cast[int64](k)] = k * 2 + 5
        k = k + 1
    total: int64 = 0
    i: int64 = 0
    while i < {N}:
        row: int64 = 0
        j: int64 = 0
        while j < {N}:
            row += A[cast[int64](i * {N} + j)] * B[cast[int64](j)]
            j += 1
        total += row + i
        i += 1
    print_u64(cast[uint64](total))
    return cast[int32](total & cast[int64](255))
""", total)

    # 2) STORE-TO-ALIASED-LOAD: `Y[i] = Y[i] + a*X[i]` reads the element it stores
    #    in the SAME iteration. RHS computed dest-driven before the store. MUST fire.
    n = 24
    Y = [(i * 5 + 1) & M for i in range(n)]
    X = [(i * 3 + 7) & M for i in range(n)]
    a = 3
    for rep in range(40):
        for i in range(n):
            Y[i] = (Y[i] + a * X[i]) & M
    s = 0
    for i in range(n):
        s = (s + Y[i]) & M
    prog("idxstore_aliased",
         f"""Y: Array[64, int64]
X: Array[64, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < {n}:
        Y[cast[int64](i)] = i * 5 + 1
        X[cast[int64](i)] = i * 3 + 7
        i = i + 1
    a: int64 = 3
    rep: int64 = 0
    while rep < 40:
        i = 0
        while i < {n}:
            Y[cast[int64](i)] = Y[cast[int64](i)] + a * X[cast[int64](i)]
            i = i + 1
        rep = rep + 1
    s: int64 = 0
    i = 0
    while i < {n}:
        s = s + Y[cast[int64](i)]
        i = i + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
""", s)

    # 3) ALL COMPARE OPS as loop bounds (signed) + SUB/MUL accumulators; the
    #    accumulator updates route, the cmp+jcc loop tests are exercised alongside.
    acc = 0
    p = 1
    for i in range(50):
        acc = (acc + i) & M          # >=  via i < 50
        if i <= 25:
            acc = (acc - 2) & M
        if i > 10:
            acc = (acc + 3) & M
        if i != 7:
            p = (p * 1) & M
    acc = (acc + p) & M
    prog("cmp_ops_signed_acc",
         """def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = 0
    p: int64 = 1
    i: int64 = 0
    while i < 50:
        acc += i
        if i <= 25:
            acc -= 2
        if i > 10:
            acc += 3
        if i != 7:
            p *= 1
        i = i + 1
    acc += p
    print_u64(cast[uint64](acc))
    return cast[int32](acc & cast[int64](255))
""", acc)

    # 4) UNSIGNED loop bound + accumulator (unsigned compare must pick jb/jae).
    accu = 0
    for i in range(40):
        accu = (accu + i * 2) & M
    prog("cmp_unsigned_acc",
         """def main(argc: int32, argv: Ptr[uint64]) -> int32:
    accu: uint64 = 0
    i: uint64 = 0
    while i < cast[uint64](40):
        accu += cast[uint64](i) * cast[uint64](2)
        i = i + cast[uint64](1)
    print_u64(accu)
    return cast[int32](cast[int64](accu) & cast[int64](255))
""", accu)

    # 5) SHORT-CIRCUIT &&/|| condition (NOT pure -> condition never routes); the
    #    accumulator inside still routes. Correctness asserted; want_fire True
    #    (the accumulator fires even though the && condition falls back).
    acc = 0
    for i in range(30):
        if i > 5 and i < 20:
            acc = (acc + i) & M
        if i < 3 or i > 26:
            acc = (acc - 1) & M
    prog("shortcircuit_cond_acc",
         """def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = 0
    i: int64 = 0
    while i < 30:
        if i > 5 and i < 20:
            acc += i
        if i < 3 or i > 26:
            acc -= 1
        i = i + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & cast[int64](255))
""", acc)

    # 6) DST-ALIASING accumulators: value reads the OLD home (`s += s + k`,
    #    `s *= s`). Routes (no dst-alias guard for augmented). MUST fire.
    s = 3
    for i in range(8):
        s = (s + (s + 1)) & M
        s = (s * s) & M
    prog("dstalias_acc",
         """def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: int64 = 3
    i: int64 = 0
    while i < 8:
        s += s + 1
        s *= s
        i = i + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
""", s)

    # 7) MIXED ELEMENT SIZES 1/2/4/8 indexed stores `arr[i] = <binop>` — sub-8
    #    truncates on the store exactly as the seed. MUST fire (the 8-byte store).
    n = 20
    a8 = [0] * n
    a4 = [0] * n
    a2 = [0] * n
    a1 = [0] * n
    for i in range(n):
        a8[i] = (i * 7 + 3) & M
        a4[i] = (i * 7 + 3) & 0xFFFFFFFF
        a2[i] = (i * 7 + 3) & 0xFFFF
        a1[i] = (i * 7 + 3) & 0xFF
    acc = 0
    for i in range(n):
        acc = (acc + a8[i] + a4[i] + a2[i] + a1[i]) & M
    prog("mixed_elem_store",
         f"""W8: Array[32, int64]
W4: Array[32, int32]
W2: Array[32, int16]
W1: Array[32, int8]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < {n}:
        W8[cast[int64](i)] = i * 7 + 3
        W4[cast[int64](i)] = cast[int32](i * 7 + 3)
        W2[cast[int64](i)] = cast[int16](i * 7 + 3)
        W1[cast[int64](i)] = cast[int8](i * 7 + 3)
        i = i + 1
    acc: int64 = 0
    i = 0
    while i < {n}:
        acc = acc + cast[int64](W8[cast[int64](i)]) + (cast[int64](W4[cast[int64](i)]) & cast[int64](4294967295)) + (cast[int64](W2[cast[int64](i)]) & cast[int64](65535)) + (cast[int64](W1[cast[int64](i)]) & cast[int64](255))
        i = i + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & cast[int64](255))
""", acc)

    # 8) NEGATIVE / ZERO index into an indexed store (`g[k] = g[k] + g[0]`).
    n = 32
    G = [(i - 10) & M for i in range(n)]
    for rep in range(20):
        base = G[0]
        for k in range(n):
            G[k] = (G[k] + base) & M
    s = 0
    for i in range(n):
        s = (s + G[i]) & M
    prog("idxstore_negzero",
         f"""G: Array[64, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    i: int64 = 0
    while i < {n}:
        G[cast[int64](i)] = i - 10
        i = i + 1
    rep: int64 = 0
    while rep < 20:
        base: int64 = G[cast[int64](0)]
        k: int64 = 0
        while k < {n}:
            G[cast[int64](k)] = G[cast[int64](k)] + base
            k = k + 1
        rep = rep + 1
    s: int64 = 0
    i = 0
    while i < {n}:
        s = s + G[cast[int64](i)]
        i = i + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
""", s)

    # 9) FALLBACK — CALL in the accumulator value (`s += sq(i)`): impure value ->
    #    ir_lower_pure_expr refuses -> legacy reload-combine-store. Correctness only.
    def sq(x):
        return (x * x) & M
    s = 0
    for i in range(20):
        s = (s + sq(i)) & M
    prog("acc_call_fallback",
         """def sq(x: int64) -> int64:
    return x * x
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    s: int64 = 0
    i: int64 = 0
    while i < 20:
        s += sq(i)
        i = i + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
""", s, want_fire=False)

    # 10) FALLBACK — IMPURE INDEX (`g[idx()] = a*b`): the index has a side effect
    #     -> the store must NOT route (address eval order would change). Correctness.
    n = 16
    G = [0] * n
    ctr = [0]
    def idx():
        v = ctr[0] % n
        ctr[0] = ctr[0] + 1
        return v
    for rep in range(n):
        G[idx()] = (3 * 5) & M
    s = 0
    for i in range(n):
        s = (s + G[i]) & M
    prog("idxstore_impure_idx_fallback",
         f"""G: Array[32, int64]
ctr: int64
def nextidx() -> int64:
    v: int64 = ctr % {n}
    ctr = ctr + 1
    return v
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    ctr = 0
    a: int64 = 3
    b: int64 = 5
    rep: int64 = 0
    while rep < {n}:
        G[cast[int64](nextidx())] = a * b
        rep = rep + 1
    s: int64 = 0
    i: int64 = 0
    while i < {n}:
        s = s + G[cast[int64](i)]
        i = i + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
""", s, want_fire=False)

    # 11) PLAIN-ASSIGN ACCUMULATOR pattern (the matmul shape `s = s + A*B`, the
    #     dst-aliasing accumulate Phase 1 refused): `name = name OP rest` and the
    #     commutative `name = rest OP name`, plus a `s = s - X` left-operand SUB.
    #     All route into the resident home. MUST fire.
    N = 10
    A = [(k * 2 + 1) & M for k in range(N * N)]
    B = [(k + 3) & M for k in range(N * N)]
    chk = 0
    for i in range(N):
        for j in range(N):
            s = 0
            for kk in range(N):
                s = (s + A[i * N + kk] * B[kk * N + j]) & M
            chk = (chk + s) & M
    # commutative `rest OP name` + left-SUB `name = name - X` woven in
    acc2 = 1000000
    for i in range(N):
        acc2 = (A[i] * 2 + acc2) & M      # rest + name
        acc2 = (acc2 - (i + 1)) & M       # name - rest (left SUB)
    chk = (chk + acc2) & M
    prog("plain_accum_matmul",
         f"""A: Array[{N*N}, int64]
B: Array[{N*N}, int64]
def main(argc: int32, argv: Ptr[uint64]) -> int32:
    Nn: int64 = {N}
    k: int64 = 0
    while k < {N*N}:
        A[cast[int64](k)] = k * 2 + 1
        B[cast[int64](k)] = k + 3
        k = k + 1
    chk: int64 = 0
    i: int64 = 0
    while i < Nn:
        j: int64 = 0
        while j < Nn:
            s: int64 = 0
            kk: int64 = 0
            while kk < Nn:
                s = s + A[cast[int64](i * Nn + kk)] * B[cast[int64](kk * Nn + j)]
                kk = kk + 1
            chk = chk + s
            j = j + 1
        i = i + 1
    acc2: int64 = 1000000
    i = 0
    while i < Nn:
        acc2 = A[cast[int64](i)] * 2 + acc2
        acc2 = acc2 - (i + 1)
        i = i + 1
    chk = chk + acc2
    print_u64(cast[uint64](chk))
    return cast[int32](chk & cast[int64](255))
""", chk)

    # 12) SCRATCH-FREE COMBINE — IMMEDIATE step boundary. The accumulator combine
    #     emits `op $imm,%home` for a constant step that fits a sign-extended imm32,
    #     and computes a >imm32 step into %rax then `op %rax,%home`. Exercise both
    #     0x83 (imm8 <128) and 0x81 (imm32) encodings + the >imm32 general path, via
    #     +=, -= and *=. MUST fire.
    acc = 0
    for i in range(200):
        acc = (acc + 1) & M               # imm8 (add $1)
        acc = (acc + 127) & M             # imm8 boundary (add $127)
        acc = (acc + 128) & M             # imm32 (add $128)
        acc = (acc + 2147483647) & M      # imm32 max (add $0x7fffffff)
        acc = (acc + 4294967296) & M      # > imm32 -> %rax combine (add %rax)
        acc = (acc - 100000) & M          # sub imm32
        acc = (acc * 3) & M               # MUL has no imm form -> general path
    prog("imm_step_boundary",
         """def main(argc: int32, argv: Ptr[uint64]) -> int32:
    acc: int64 = 0
    i: int64 = 0
    while i < 200:
        acc += 1
        acc += 127
        acc += 128
        acc += 2147483647
        acc += 4294967296
        acc -= 100000
        acc *= 3
        i = i + 1
    print_u64(cast[uint64](acc))
    return cast[int32](acc & cast[int64](255))
""", acc)

    # 13) SCRATCH-FREE COMBINE — AND/OR/XOR IMMEDIATE in a dest-driven root (`x =
    #     (expr) & const`). These ops are not augmented-accumulator-routed but the
    #     Phase-1 dest selector folds the constant right operand to `op $imm,%home`.
    #     MUST fire (DESTSEL via try_sel_assign — counted as accsel? no — destsel).
    msk = 0
    for i in range(150):
        v = (i * 2654435761) & M
        msk = ((((v + 7) & 1048575) | (i & 4080)) ^ 255) & M
    prog("bitop_imm_dest",
         """def main(argc: int32, argv: Ptr[uint64]) -> int32:
    msk: int64 = 0
    i: int64 = 0
    while i < 150:
        v: int64 = i * 2654435761
        msk = ((((v + 7) & 1048575) | (i & 4080)) ^ 255)
        i = i + 1
    print_u64(cast[uint64](msk))
    return cast[int32](msk & cast[int64](255))
""", msk, want_fire=False)

    # 14) SCRATCH-FREE COMBINE — REGISTER-RESIDENT IDENT value (`s += m`, m a
    #     loop-invariant promoted local) under HIGH REGISTER PRESSURE (many live
    #     locals), so the combine takes the `op %srcreg,%home` form AND the pool is
    #     exhausted enough to drive the no-scratch %rax path elsewhere. MUST fire.
    m1, m2, m3, m4, m5, m6 = 11, 13, 17, 19, 23, 29
    s = 0
    t = 0
    u = 0
    for i in range(300):
        s = (s + m1 + m2 * i) & M
        t = (t + m3 - m4) & M
        u = (u + m5 * m6 + i) & M
        s = (s + t + u) & M
    prog("regident_pressure_acc",
         """def main(argc: int32, argv: Ptr[uint64]) -> int32:
    m1: int64 = 11
    m2: int64 = 13
    m3: int64 = 17
    m4: int64 = 19
    m5: int64 = 23
    m6: int64 = 29
    s: int64 = 0
    t: int64 = 0
    u: int64 = 0
    i: int64 = 0
    while i < 300:
        s = s + m1 + m2 * i
        t = t + m3 - m4
        u = u + m5 * m6 + i
        s = s + t + u
        i = i + 1
    print_u64(cast[uint64](s))
    return cast[int32](s & cast[int64](255))
""", s)

    # (FLOAT accumulator/element fallback — `fs += a*b`, float arrays — is asserted
    #  by scripts/test_opt_isel_store.sh (ON==OFF, ACCSEL/IDXSTORE==0) and the
    #  dedicated iremit_float_check corpus; the cast[int64](float) value is not a
    #  stable static oracle in this minimal subset, so it is not pinned here.)

    # 11) FALLBACK — SUB-8-BYTE scalar accumulator (`c: int32; c += ...`): the
    #     sized slot store must run -> not routed. Correctness only.
    c = 0
    for i in range(30):
        c = (c + i * 3) & 0xFFFFFFFF
    cs = c if c < (1 << 31) else c - (1 << 32)
    prog("sub8_acc_fallback",
         """def main(argc: int32, argv: Ptr[uint64]) -> int32:
    c: int32 = 0
    i: int32 = 0
    while i < 30:
        c += i * 3
        i = i + 1
    print_u64(cast[uint64](cast[int64](c)))
    return cast[int32](cast[int64](c) & cast[int64](255))
""", cs & M, want_fire=False)

    return progs


def _run_p3store_corpus():
    """Run the Phase-3 store-glue corpus through codegen.ad.
    Returns (all_ok, total_routed)."""
    host = _ad_host()
    total = 0
    all_ok = True
    fired_any = False
    for (name, body, exp_out, exp_exit, want_fire) in _p3store_corpus():
        r_on = host.run_through_codegen_ad(f"p3_{name}", body, _AD_WORK, opt=True)
        r_off = host.run_through_codegen_ad(f"p3_{name}o", body, _AD_WORK, opt=False)
        if r_on.kind != "ok" or r_off.kind != "ok":
            all_ok = False
            print(f"  [P3STORE corpus '{name}'] codegen.ad on={r_on.kind}/off={r_off.kind}: "
                  f"{(r_on.detail or r_off.detail)[:120]}")
            continue
        acc = int(getattr(r_on, "accsel", 0) or 0)
        idx = int(getattr(r_on, "idxstore", 0) or 0)
        routed = acc + idx
        total += routed
        if routed > 0:
            fired_any = True
        # (a) correctness vs oracle for BOTH on and off.
        if r_on.stdout != exp_out or r_on.exit != exp_exit:
            all_ok = False
            print(f"  [P3STORE corpus '{name}'] MISCOMPILE on=({r_on.stdout},{r_on.exit}) "
                  f"oracle=({exp_out},{exp_exit}) accsel={acc} idxstore={idx}")
            continue
        if r_off.stdout != exp_out or r_off.exit != exp_exit:
            all_ok = False
            print(f"  [P3STORE corpus '{name}'] OFF path wrong off=({r_off.stdout},{r_off.exit}) "
                  f"oracle=({exp_out},{exp_exit})")
            continue
        # (b) a want_fire program MUST route at least one store (ACCSEL+IDXSTORE>0).
        if want_fire and routed == 0:
            all_ok = False
            print(f"  [P3STORE corpus '{name}'] correct but NO STORE ROUTED "
                  f"(want_fire=True)")
            continue
        # (c) OFF is byte-inert: re-dump off, assert ACCSEL==0 and IDXSTORE==0.
        src = _AD_WORK / f"p3_mc_{name}.ad"
        src.write_text(host.codegen_compatible_source(body))
        d_off = host.run_dump(src, opt=False)
        if d_off.status == "ok" and (getattr(d_off, "accsel", 0) != 0 or
                                     getattr(d_off, "idxstore", 0) != 0):
            all_ok = False
            print(f"  [P3STORE corpus '{name}'] OFF path NOT byte-inert: "
                  f"ACCSEL={getattr(d_off,'accsel',0)} IDXSTORE={getattr(d_off,'idxstore',0)}")
            continue
    if not fired_any:
        all_ok = False
        print("  [P3STORE corpus FAIL] no program exercised the store-glue levers")
    return (all_ok, total)


# --------------------------------------------------------------------------
# Phase-4 REGISTER-PRESSURE corpus. Hand-written programs with MANY
# simultaneously-live scalar locals — more than the 5-register callee-saved pool
# — so the linear-scan allocator is FORCED to spill, plus call-crossing values
# (locals live across a function call held in callee-saved regs). Each program
# computes a deterministic checksum into g_accum that the Python oracle predicts
# exactly, so correctness UNDER SPILLING is asserted against the seed oracle, and
# the --dump-regalloc lane separately confirms the allocator actually put values
# in registers AND spilled (pressure was real). All arithmetic is over the
# signedness-invariant 64-bit op set so the oracle is a plain Python uint64.
# --------------------------------------------------------------------------
def _regpressure_corpus():
    """Return a list of (name, body, expected_stdout, expected_exit)."""
    M = (1 << 64) - 1
    progs = []

    def prog(name, decls_and_main, val):
        body = PRELUDE + "\n" + decls_and_main
        progs.append((name, body, str(val & M), val & 0xFF))

    # 1) Ten live locals summed simultaneously: all ten are live across the final
    #    sum, far exceeding the 5-register pool => guaranteed spills. Pure
    #    arithmetic, no calls.
    vals = [3, 5, 7, 11, 13, 17, 19, 23, 29, 31]
    decls = "".join(
        f"    v{i}: uint64 = cast[uint64]({v})\n" for i, v in enumerate(vals))
    summ = " + ".join(f"v{i}" for i in range(len(vals)))
    total = sum(vals) & M
    prog("ten_live_sum",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         + decls
         + f"    g_accum = {summ}\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         total)

    # 2) Eight live locals, each multiplied by the next, threaded so ALL stay
    #    live to the end (a chain that references every earlier local again).
    a = [2, 3, 4, 5, 6, 7, 8, 9]
    decls = "".join(
        f"    w{i}: uint64 = cast[uint64]({v})\n" for i, v in enumerate(a))
    # acc = ((...((w0*w1)+w2)*w3+...)) then + sum of all wi (forces each wi live
    # at the final reference).
    expr = "w0"
    acc = a[0]
    for i in range(1, len(a)):
        if i % 2 == 0:
            expr = f"(({expr}) + w{i})"
            acc = (acc + a[i]) & M
        else:
            expr = f"(({expr}) * w{i})"
            acc = (acc * a[i]) & M
    tail = " + ".join(f"w{i}" for i in range(len(a)))
    acc = (acc + sum(a)) & M
    prog("eight_chain_plus_sum",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         + decls
         + f"    g_accum = ({expr}) + ({tail})\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         acc)

    # 3) CALL-CROSSING pressure: seven locals defined, then a CALL (print_u64),
    #    then all seven summed AFTER the call — every local is live across the
    #    call, so the allocator must keep them in CALLEE-SAVED registers (or
    #    spill). The call also prints an intermediate value (observable), and the
    #    final checksum proves none of the seven was corrupted by the call.
    cvals = [101, 202, 303, 404, 505, 606, 707]
    decls = "".join(
        f"    c{i}: uint64 = cast[uint64]({v})\n" for i, v in enumerate(cvals))
    presum = cvals[0] & M
    postsum = sum(cvals) & M
    summ = " + ".join(f"c{i}" for i in range(len(cvals)))
    # prints c0 first (presum), then the full sum.
    prog("seven_callcross",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         + decls
         + "    print_u64(c0)\n"
         + f"    g_accum = {summ}\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         postsum)
    # fix expected stdout: two lines (presum then postsum).
    nm, bd, _, _ = progs[-1]
    progs[-1] = (nm, bd, f"{presum}\n{postsum}", postsum & 0xFF)

    # 4) Spills INSIDE a loop: 6 loop-carried accumulators updated each iteration
    #    (all live across the back-edge), exceeding the pool by one => at least
    #    one spilled accumulator that must round-trip correctly every iteration.
    decls = "".join(f"    s{i}: uint64 = cast[uint64]({i + 1})\n" for i in range(6))
    s = [i + 1 for i in range(6)]
    n_iter = 5
    for _ in range(n_iter):
        s = [(s[i] + (i + 1)) & M for i in range(6)]
    loopsum = sum(s) & M
    upd = "".join(
        f"        s{i} = s{i} + cast[uint64]({i + 1})\n" for i in range(6))
    fin = " + ".join(f"s{i}" for i in range(6))
    prog("six_loop_accum_spill",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         + decls
         + "    lk: int64 = 0\n"
         + f"    while lk < cast[int64]({n_iter}):\n"
         + upd
         + "        lk = lk + 1\n"
         + f"    g_accum = {fin}\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         loopsum)

    # 5) P3 SPILL-COST: a hot reduction accumulator vs many short-lived temps.
    #    `acc` is updated EVERY iteration (huge loop-weighted use cost) while a
    #    rotating set of straight-line temps t0..t7 are each live only briefly.
    #    The spill-cost heuristic must KEEP acc register-resident (not evict it
    #    by the old furthest-end rule). Correctness proves acc round-trips right
    #    whatever the allocator chose; the value is the soundness gate.
    n_iter2 = 9
    acc = 0
    for it in range(n_iter2):
        t0 = (it * 3 + 1) & M
        t1 = (t0 + 5) & M
        t2 = (t1 * 2) & M
        t3 = (t2 + it) & M
        acc = (acc + t0 + t1 + t2 + t3) & M
    prog("hot_accum_vs_temps",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    acc: uint64 = cast[uint64](0)\n"
         "    it: int64 = cast[int64](0)\n"
         + f"    while it < cast[int64]({n_iter2}):\n"
         "        t0: uint64 = cast[uint64](it) * cast[uint64](3) + cast[uint64](1)\n"
         "        t1: uint64 = t0 + cast[uint64](5)\n"
         "        t2: uint64 = t1 * cast[uint64](2)\n"
         "        t3: uint64 = t2 + cast[uint64](it)\n"
         "        acc = acc + t0 + t1 + t2 + t3\n"
         "        it = it + cast[int64](1)\n"
         "    g_accum = acc\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         acc)

    # 6) CALL-FREE deep loop nest with many simultaneously-live values: a 2-deep
    #    nest where 8 accumulators are carried across BOTH back-edges. No call
    #    anywhere => the caller-saved pool expansion (rdi/r8-r11) is eligible, so
    #    the allocator can hold all 8 without spilling. Correctness under the
    #    expanded pool is the gate (a mis-encoded caller-saved reg write would
    #    corrupt the result — exactly the bug the general mov encoders fixed).
    k = [1, 2, 3, 4, 5, 6, 7, 8]
    OI, IJ = 4, 3
    for _oi in range(OI):
        for _ij in range(IJ):
            # SEQUENTIAL in-place updates (mirror the emitted statement order):
            # k{i} reads the CURRENT k{(i+1)%8}, which for i=7 is the already-
            # updated k0.
            for i in range(8):
                k[i] = (k[i] + k[(i + 1) % 8] + (i + 1)) & M
    nestsum = sum(k) & M
    kdecls = "".join(f"    k{i}: uint64 = cast[uint64]({i + 1})\n" for i in range(8))
    kupd = "".join(
        f"            k{i} = k{i} + k{(i + 1) % 8} + cast[uint64]({i + 1})\n"
        for i in range(8))
    kfin = " + ".join(f"k{i}" for i in range(8))
    # NOTE: this program makes NO call (no print_u64) — it returns only an exit
    # code — so cfg_fn_has_call==0 and the allocator may use the caller-saved
    # extension pool. The corpus runner asserts RA_MAX_REGS>5 is reached SOMEWHERE
    # across the corpus, which this program provides.
    prog("callfree_nest_8live",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         + kdecls
         + "    oi: int64 = cast[int64](0)\n"
         + f"    while oi < cast[int64]({OI}):\n"
         + "        ij: int64 = cast[int64](0)\n"
         + f"        while ij < cast[int64]({IJ}):\n"
         + kupd
         + "            ij = ij + cast[int64](1)\n"
         + "        oi = oi + cast[int64](1)\n"
         + f"    g_accum = {kfin}\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         nestsum)
    # this program prints nothing: override expected stdout to empty.
    nm, bd, _, _ = progs[-1]
    progs[-1] = (nm, bd, "", nestsum & 0xFF)

    # 7) MUST-NOT-CLOBBER: a loop with a CALL in the body, carrying a value
    #    `carry` ACROSS the call every iteration. Because the function makes a
    #    call, the allocator MUST stay callee-saved-only — a value left in a
    #    caller-saved register would be destroyed by the call's clobbers. The
    #    final checksum proves `carry` survived every call. The call prints an
    #    observable intermediate so the stdout is also checked.
    carry = 0
    base7 = 7
    n7 = 6
    printed = []
    for it in range(n7):
        printed.append(str((base7 + it) & M))
        carry = (carry + base7 + it) & M
    prog("loop_call_carry",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    carry: uint64 = cast[uint64](0)\n"
         + f"    base7: uint64 = cast[uint64]({base7})\n"
         "    it: int64 = cast[int64](0)\n"
         + f"    while it < cast[int64]({n7}):\n"
         "        cur: uint64 = base7 + cast[uint64](it)\n"
         "        print_u64(cur)\n"
         "        carry = carry + cur\n"
         "        it = it + cast[int64](1)\n"
         "    g_accum = carry\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         carry)
    nm, bd, _, _ = progs[-1]
    progs[-1] = (nm, bd, "\n".join(printed + [str(carry & M)]), carry & 0xFF)

    # 8) ALIASING WRITEBACK: a local whose ADDRESS is taken and written through a
    #    pointer inside a loop. Such a local is NOT register-promotable (the alias
    #    analysis marks it clobberable), so it MUST stay on the memory path even
    #    under the expanded pool. The checksum proves the pointer writeback and
    #    the surrounding register-resident accumulator stay coherent.
    aw_acc = 0
    aw_box = 0
    n8 = 7
    for it in range(n8):
        aw_box = (it * 2 + 1) & M           # written through &box
        aw_acc = (aw_acc + aw_box) & M
    prog("alias_writeback_loop",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    box: uint64 = cast[uint64](0)\n"
         "    aw_acc: uint64 = cast[uint64](0)\n"
         "    p: Ptr[uint64] = &box\n"
         "    it: int64 = cast[int64](0)\n"
         + f"    while it < cast[int64]({n8}):\n"
         "        p[cast[int64](0)] = cast[uint64](it) * cast[uint64](2) + cast[uint64](1)\n"
         "        aw_acc = aw_acc + box\n"
         "        it = it + cast[int64](1)\n"
         "    g_accum = aw_acc\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         aw_acc)

    return progs


def _run_regpressure_corpus():
    """Run the register-pressure corpus through codegen.ad with --opt and assert
    BOTH (a) the spilled/register-allocated output is correct vs the oracle AND
    (b) the --dump-regalloc lane confirms the allocator put values in registers
    and that real pressure (a spill, or full pool use) occurred across the corpus.
    Returns (all_ok, total_inreg, total_spilled, max_regs)."""
    host = _ad_host()
    all_ok = True
    total_inreg = 0
    total_spilled = 0
    max_regs = 0
    total_regmove_progs = 0   # programs whose --opt MACHINE CODE shows reg moves
    from pathlib import Path as _Path

    # --- x86-64 opcode signatures emitted by the regalloc backend (codegen.ad
    #     emit_push_callee / emit_mov_callee_rax / emit_mov_rax_callee). These
    #     bytes are how a promoted local actually LIVES in a callee-saved
    #     register, vs the default %rbp-slot load/store. The --dump-regalloc lane
    #     is pure analysis; this asserts the EMITTED CODE genuinely changed.
    #       push %rbx -> 53 ; push %r12..%r15 -> 41 54..41 57
    #       mov %rbx,%rax -> 48 8b c3 ; mov %r12..%r15,%rax -> 49 8b c4..c7
    #       mov %rax,%rbx -> 48 89 c3 ; mov %rax,%r12..%r15 -> 49 89 c4..c7
    _CALLEE_PUSH = (bytes([0x53]), bytes([0x41, 0x54]), bytes([0x41, 0x55]),
                    bytes([0x41, 0x56]), bytes([0x41, 0x57]))
    # Register READ moves `mov %<enc>,%rax` and WRITE moves `mov %rax,%<enc>`,
    # over BOTH the callee-saved pool (rbx=3, r12..r15) AND the call-free
    # caller-saved extension (rdi=7, r8..r11). REX.W=0x48, +REX.B=0x49 when the
    # r/m encoding is r8..r15; modrm = 0xC0 | (enc & 7).
    _POOL_ENCS = (3, 7, 8, 9, 10, 11, 12, 13, 14, 15)
    def _rmove(op):
        pats = []
        for e in _POOL_ENCS:
            rex = 0x48 | (0x01 if e >= 8 else 0)
            pats.append(bytes([rex, op, 0xC0 | (e & 7)]))
        return pats
    _REG_READ = _rmove(0x8b)
    _REG_WRITE = _rmove(0x89)

    def _contains_any(blob, pats):
        return any(p in blob for p in pats)

    for (name, body, exp_out, exp_exit) in _regpressure_corpus():
        r = host.run_through_codegen_ad(f"rp_{name}", body, _AD_WORK, opt=True)
        if r.kind != "ok":
            all_ok = False
            print(f"  [REGPRESSURE '{name}'] codegen.ad {r.kind}: {r.detail[:140]}")
            continue
        if r.stdout != exp_out or r.exit != exp_exit:
            all_ok = False
            print(f"  [REGPRESSURE '{name}'] MISCOMPILE opt=("
                  f"{r.stdout!r},{r.exit}) oracle=({exp_out!r},{exp_exit})")
            continue
        # allocation stats from the --dump-regalloc lane (pure analysis).
        ra = host.run_regalloc_over_body(f"rp_{name}", body, _AD_WORK)
        if ra.status != "raok":
            all_ok = False
            print(f"  [REGPRESSURE '{name}'] regalloc lane {ra.status}: {ra.detail[:120]}")
            continue
        total_inreg += ra.inreg
        total_spilled += ra.spilled
        max_regs = max(max_regs, ra.max_regs)

        # MACHINE-CODE proof: dump the emitted bytes with --opt ON and OFF and
        # assert the ON image actually uses callee-saved registers (push + a
        # register read/write move) while the OFF image does NOT push any
        # callee-saved reg (so the bytes genuinely differ — the registers are
        # real instructions, not just an analysis annotation, and the OFF path
        # is byte-inert).
        src = _AD_WORK / f"rpmc_{name}.ad"
        src.write_text(body)
        d_on = host.run_dump(src, opt=True)
        d_off = host.run_dump(src, opt=False)
        if d_on.status != "ok" or d_off.status != "ok":
            all_ok = False
            print(f"  [REGPRESSURE '{name}'] dump status on={d_on.status} "
                  f"off={d_off.status}")
            continue
        on_push = _contains_any(d_on.code, _CALLEE_PUSH)
        on_read = _contains_any(d_on.code, _REG_READ)
        on_write = _contains_any(d_on.code, _REG_WRITE)
        off_push = _contains_any(d_off.code, _CALLEE_PUSH)
        # A program that actually register-allocated (ra.inreg > 0) MUST show a
        # pool register move under --opt (callee-saved OR the caller-saved
        # extension). The push is required ONLY if a callee-saved reg was used:
        # a purely caller-saved (call-free) allocation emits no callee-saved
        # push, which is correct (those regs need no save/restore).
        if ra.inreg > 0 and not (on_read or on_write):
            all_ok = False
            print(f"  [REGPRESSURE '{name}'] EMITTED CODE shows no pool register "
                  f"move under --opt (read={on_read} write={on_write} "
                  f"inreg={ra.inreg})")
            continue
        if off_push:
            all_ok = False
            print(f"  [REGPRESSURE '{name}'] OFF path is NOT byte-inert: emitted a "
                  f"callee-saved push with the flag off")
            continue
        if ra.inreg > 0 and d_on.code == d_off.code:
            all_ok = False
            print(f"  [REGPRESSURE '{name}'] --opt did not change the emitted code")
            continue
        if on_read or on_write:
            total_regmove_progs += 1
    # The corpus must (a) be all-correct, (b) demonstrably register-allocate, and
    # (c) demonstrably hit pressure (a spill OR the full 5-reg pool somewhere).
    if total_inreg == 0:
        all_ok = False
        print("  [REGPRESSURE FAIL] allocator never placed a value in a register")
    if total_spilled == 0 and max_regs < 5:
        all_ok = False
        print("  [REGPRESSURE FAIL] no register pressure exercised (no spill, pool not full)")
    if total_regmove_progs == 0:
        all_ok = False
        print("  [REGPRESSURE FAIL] no program emitted a callee-saved register move "
              "under --opt (the allocator's assignments never reached the machine code)")
    # P3 caller-saved EXPANSION must fire somewhere: a call-free pressured
    # function exceeds the 5-register callee-saved pool (RA_MAX_REGS > 5).
    if max_regs <= 5:
        all_ok = False
        print("  [REGPRESSURE FAIL] caller-saved pool expansion never fired "
              f"(max RA_MAX_REGS={max_regs} <= 5); call-free pressure unexercised")
    return (all_ok, total_inreg, total_spilled, max_regs, total_regmove_progs)


# --------------------------------------------------------------------------
# STORE-THROUGH-ELIMINATION corpus (the write-through store lever). A fully
# register-promoted plain scalar with NO slot-bypass read loses its shadow stack
# slot store: store_to_named writes ONLY the register. This corpus is the
# soundness net for that elimination. It deliberately exercises EVERY codegen
# read path that touches a NAMED scalar local, so a MISSED slot-read (a read
# left on the stale stack slot after the store was dropped) becomes a wrong
# answer the oracle catches:
#   * a promoted accumulator updated in a loop then READ AFTER the loop,
#   * a promoted scalar read as an ALU operand, a call ARG, RETURNED, COMPARED,
#   * SOUNDNESS (must KEEP the store / NOT eliminate):
#       - a scalar-as-pointer base `p[i]` (gen_index_address reads p's slot),
#       - a for-loop INDUCTION variable (emit_load_for_var reads the slot),
#       - a LOCAL function-pointer callee (gen_call reads the slot),
#       - an ADDRESS-TAKEN local (`&x`; already non-promotable, slot mandatory),
#     each updated AND read through the bypass path so a wrong elimination
#     would diverge,
#   * a value promoted in part of the function and spilled in another (heavy
#     register pressure) — the elimination must only fire where it has a reg.
# All arithmetic is over the signedness-invariant 64-bit op set so the oracle is
# a plain Python uint64. The harness ALSO asserts STOREELIM>0 fired and is
# byte-inert OFF (STOREELIM==0 with the flag off).
# --------------------------------------------------------------------------
def _storethrough_corpus():
    """Return a list of (name, body, expected_stdout, expected_exit)."""
    M = (1 << 64) - 1
    progs = []

    def prog(name, decls_and_main, val):
        body = PRELUDE + "\n" + decls_and_main
        progs.append((name, body, str(val & M), val & 0xFF))

    # 1) ELIMINABLE accumulator: a hot single-scalar reduction read AFTER the
    #    loop. `s` is a plain scalar, never indexed/address-taken/for-IV, so its
    #    per-iteration store should be DROPPED — yet the post-loop read must see
    #    the final value (the register IS the value). Few locals -> `s` gets a
    #    register; the elimination is the whole point.
    acc = 0
    for k in range(100):
        acc = (acc + (k * 3 + 1)) & M
    prog("hot_accum_readback",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    s: uint64 = cast[uint64](0)\n"
         "    k: uint64 = cast[uint64](0)\n"
         "    while k < cast[uint64](100):\n"
         "        s = s + (k * cast[uint64](3) + cast[uint64](1))\n"
         "        k = k + cast[uint64](1)\n"
         "    g_accum = s\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         acc)

    # 2) Promoted scalar read through MANY paths: ALU operand, compare, call ARG
    #    (print_u64), and RETURNED. Each is a distinct codegen read that must
    #    route to the register after the store is eliminated.
    x = (7 * 11 + 5) & M          # x = 82
    y = (x * 2) & M               # ALU operand
    cmpres = 1 if x > 50 else 0   # compare
    ret = (y + cmpres) & M
    prog("read_many_paths",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    x: uint64 = cast[uint64](7) * cast[uint64](11) + cast[uint64](5)\n"
         "    print_u64(x)\n"                       # call arg
         "    y: uint64 = x * cast[uint64](2)\n"    # ALU operand
         "    r: uint64 = y\n"
         "    if x > cast[uint64](50):\n"           # compare
         "        r = r + cast[uint64](1)\n"
         "    g_accum = r\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](r) & cast[uint64](255))\n",
         ret)
    nm, bd, _, _ = progs[-1]
    progs[-1] = (nm, bd, f"{x}\n{ret}", ret & 0xFF)

    # 3) SOUNDNESS — scalar-as-pointer base `p[i]`. `p` holds the address of a
    #    global array; it is UPDATED (p = p + 8 to walk) AND used as `p[0]`. The
    #    index base read goes through the SLOT (gen_index_address), so `p` MUST
    #    stay write-through even if promoted. A missed slot-read here reads a
    #    stale base => wrong element => oracle divergence.
    base_vals = [11, 22, 33, 44]
    s3 = sum(base_vals) & M
    decl3 = "g_arr3: Array[4, uint64]\n"
    fill3 = "".join(
        f"    g_arr3[cast[int64]({i})] = cast[uint64]({v})\n"
        for i, v in enumerate(base_vals))
    prog("scalar_ptr_base_walk",
         decl3 +
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         + fill3 +
         "    p: uint64 = cast[uint64](&g_arr3[cast[int64](0)])\n"
         "    acc: uint64 = cast[uint64](0)\n"
         "    n: uint64 = cast[uint64](0)\n"
         "    while n < cast[uint64](4):\n"
         "        acc = acc + p[cast[int64](0)]\n"   # reads p's SLOT as base
         "        p = p + cast[uint64](8)\n"         # update p
         "        n = n + cast[uint64](1)\n"
         "    g_accum = acc\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         s3)

    # 4) SOUNDNESS — for-loop INDUCTION variable. `i` is a range-loop IV read by
    #    emit_load_for_var (loop test + step) from its slot, so it MUST stay
    #    write-through; the body ALSO reads `i` as an ALU operand (register path).
    s4 = 0
    for i in range(20):
        s4 = (s4 + i * i) & M
    prog("for_iv_soundness",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    acc: uint64 = cast[uint64](0)\n"
         "    for i in range(20):\n"
         "        acc = acc + cast[uint64](i) * cast[uint64](i)\n"
         "    g_accum = acc\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         s4)

    # 5) SOUNDNESS — ADDRESS-TAKEN local. `t` has its address taken and is
    #    written THROUGH the pointer, so it is non-promotable: its slot is the
    #    only home and the store must stay. Read back after the through-store —
    #    the through-store REPLACES t's value (37), so a wrong (eliminated) read
    #    of a stale register/slot would diverge.
    t_final = 37 & M
    prog("addr_taken_keep_slot",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         "    t: uint64 = cast[uint64](5)\n"
         "    q: Ptr[uint64] = &t\n"
         "    q[cast[int64](0)] = cast[uint64](37)\n"   # store THROUGH ptr -> slot
         "    g_accum = t\n"                            # must read the slot value
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         t_final)

    # 6) PARTIAL promotion under pressure: 8 simultaneously-live accumulators
    #    updated in a loop (exceeds the 5-reg pool, this fn is call-free so the
    #    extension pool helps but pressure still forces a spill), each read after
    #    the loop. Whichever get a register lose their store; the spilled ones
    #    keep theirs. All must be correct.
    n6 = 40
    accs = [0] * 8
    for it in range(n6):
        for j in range(8):
            accs[j] = (accs[j] + (it + j + 1)) & M
    total6 = sum(accs) & M
    decls6 = "".join(f"    a{j}: uint64 = cast[uint64](0)\n" for j in range(8))
    upd6 = "".join(
        f"        a{j} = a{j} + (it + cast[uint64]({j + 1}))\n" for j in range(8))
    sum6 = " + ".join(f"a{j}" for j in range(8))
    prog("partial_promote_pressure",
         "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
         + decls6 +
         "    it: uint64 = cast[uint64](0)\n"
         "    while it < cast[uint64](40):\n"
         + upd6 +
         "        it = it + cast[uint64](1)\n"
         f"    g_accum = {sum6}\n"
         "    print_u64(g_accum)\n"
         "    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))\n",
         total6)

    # (NOTE: a LOCAL function-pointer callee is ALSO sr_mark'd in cfg.ad so its
    #  slot stays write-through, but the Fn[...] local-fnptr syntax is outside
    #  the codegen.ad differential subset (parsefail), so it cannot be exercised
    #  through this host harness; its soundness rests on the cfg sr_mark guard +
    #  the flag-OFF objdiff/kobjdiff invariance.)

    return progs


def _run_storethrough_corpus():
    """Run the store-through-elimination corpus through codegen.ad with --opt.
    Asserts (a) correctness vs the oracle for EVERY program (catches a missed
    slot-read on the eliminated-store path), (b) the elimination demonstrably
    FIRED (STOREELIM>0 across the corpus), (c) it is byte-inert OFF
    (STOREELIM==0 with --opt off) and ON!=OFF bytes somewhere, and (d) the
    soundness programs (scalar-ptr base, for-IV, address-taken, fnptr callee)
    are correct — i.e. the value still flows through the kept slot.
    Returns (all_ok, total_storeelim)."""
    host = _ad_host()
    all_ok = True
    total_storeelim = 0
    fired_any = False
    changed_any = False
    for (name, body, exp_out, exp_exit) in _storethrough_corpus():
        r_on = host.run_through_codegen_ad(f"st_{name}", body, _AD_WORK, opt=True)
        r_off = host.run_through_codegen_ad(f"st_{name}o", body, _AD_WORK, opt=False)
        if r_on.kind != "ok" or r_off.kind != "ok":
            all_ok = False
            print(f"  [STORETHROUGH '{name}'] codegen.ad on={r_on.kind}/off={r_off.kind}: "
                  f"{(r_on.detail or r_off.detail or '')[:140]}")
            continue
        # (a) correctness vs oracle, ON AND OFF (a missed slot-read on the
        #     eliminated path makes ON diverge; OFF is the unoptimized reference).
        if r_on.stdout != exp_out or r_on.exit != exp_exit:
            all_ok = False
            print(f"  [STORETHROUGH '{name}'] MISCOMPILE (--opt ON) on=("
                  f"{r_on.stdout!r},{r_on.exit}) oracle=({exp_out!r},{exp_exit}) "
                  f"storeelim={r_on.storeelim}")
            continue
        if r_off.stdout != exp_out or r_off.exit != exp_exit:
            all_ok = False
            print(f"  [STORETHROUGH '{name}'] OFF path wrong off=("
                  f"{r_off.stdout!r},{r_off.exit}) oracle=({exp_out!r},{exp_exit})")
            continue
        se_on = int(getattr(r_on, "storeelim", 0) or 0)
        se_off = int(getattr(r_off, "storeelim", 0) or 0)
        total_storeelim += se_on
        if se_on > 0:
            fired_any = True
        # (c) byte-inert OFF: the store-elimination counter MUST be 0 with the
        #     flag off (the whole register hook is inert).
        if se_off != 0:
            all_ok = False
            print(f"  [STORETHROUGH '{name}'] OFF path NOT byte-inert: STOREELIM={se_off}")
            continue
        # MACHINE-CODE proof: when elimination fired, the ON image must differ
        # from OFF (a real store dropped, not just an annotation).
        src = _AD_WORK / f"stmc_{name}.ad"
        src.write_text(host.codegen_compatible_source(body))
        d_on = host.run_dump(src, opt=True)
        d_off = host.run_dump(src, opt=False)
        if d_on.status == "ok" and d_off.status == "ok":
            if int(getattr(d_off, "storeelim", 0) or 0) != 0:
                all_ok = False
                print(f"  [STORETHROUGH '{name}'] OFF dump STOREELIM!=0")
                continue
            if se_on > 0 and d_on.code != d_off.code:
                changed_any = True
    if not fired_any:
        all_ok = False
        print("  [STORETHROUGH FAIL] no program eliminated a write-through store "
              "(STOREELIM==0 across the corpus)")
    if not changed_any:
        all_ok = False
        print("  [STORETHROUGH FAIL] store-elimination never changed the emitted "
              "machine code (ON==OFF everywhere)")
    return (all_ok, total_storeelim)


# --------------------------------------------------------------------------
# Phase-4 METHOD register-pressure corpus. Class METHOD bodies (def m(self,...))
# were previously kept entirely on the all-memory path (gen_method forced
# cg_ra_active=0); only top-level functions were register-promoted. This corpus
# proves the increment that wires gen_method through the SAME linear-scan
# allocator: a class method with MORE simultaneously-live scalar locals than the
# 5-register pool, where the surrounding free functions (main, _putc, helpers)
# have NO register pressure. So:
#   * correctness UNDER METHOD SPILLING is asserted vs a computed oracle, AND
#   * a callee-saved push/move anywhere in the image can ONLY come from the
#     METHOD body (the free functions never exhaust the pool) — a tight machine-
#     code proof that promotion now reaches methods, while OFF stays byte-inert.
# All arithmetic is over the signedness-invariant 64-bit op set.
# --------------------------------------------------------------------------
def _method_regpressure_corpus():
    """Return a list of (name, body, expected_stdout, expected_exit). Each body
    is self-contained (its own minimal PRELUDE-free I/O) so the ONLY function
    that can hit register pressure is the method under test."""
    M = (1 << 64) - 1
    progs = []

    # Minimal I/O helpers with at most a couple of locals — far under the 5-reg
    # pool, so they NEVER push a callee-saved register. Any callee push in the
    # emitted image therefore proves the METHOD body promoted.
    IO = (
        "extern def sys_write(fd: int32, buf: Ptr[uint8], count: uint64) -> int64\n"
        "_ch: Array[1, uint8]\n"
        "def _putc(c: uint8) -> int32:\n"
        "    _ch[0] = c\n"
        "    sys_write(cast[int32](1), &_ch[0], cast[uint64](1))\n"
        "    return 0\n"
        "def emit3(v: uint64) -> int32:\n"
        "    _putc(cast[uint8](v / cast[uint64](100) + cast[uint64](48)))\n"
        "    _putc(cast[uint8]((v / cast[uint64](10)) - (v / cast[uint64](100)) * cast[uint64](10) + cast[uint64](48)))\n"
        "    _putc(cast[uint8](v - (v / cast[uint64](10)) * cast[uint64](10) + cast[uint64](48)))\n"
        "    _putc(cast[uint8](10))\n"
        "    return 0\n"
    )

    # 1) Eight live locals inside ONE method, all summed at the end. The method
    #    is call-free, so the allocator register-allocates them; under the P3
    #    caller-saved pool expansion a call-free method reaches >5 distinct regs
    #    (RA_MAX_REGS > 5), the pressure proof. x is the method param (also a
    #    promotable named scalar).
    NLIVE = 8
    decls = "".join(
        f"        m{i}: uint64 = x + cast[uint64]({i + 1})\n" for i in range(NLIVE))
    summ = " + ".join(f"m{i}" for i in range(NLIVE))
    x0 = 4
    total = sum((x0 + (i + 1)) for i in range(NLIVE)) & M
    body1 = (
        IO
        + "class Crunch:\n"
        + "    tag: uint64\n"
        + "    def __init__(self):\n"
        + "        self.tag = cast[uint64](0)\n"
        + "    def crunch(self, x: uint64) -> uint64:\n"
        + decls
        + f"        s: uint64 = {summ}\n"
        + "        return s\n"
        + "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
        + "    o: Crunch = Crunch()\n"
        + f"    r: uint64 = o.crunch(cast[uint64]({x0}))\n"
        + "    emit3(r)\n"
        + "    return cast[int32](r & cast[uint64](255))\n"
    )
    progs.append(("method_eight_live", body1,
                  f"{total % 1000:03d}", total & 0xFF))

    # 2) METHOD loop-carried spill: six accumulators updated each iteration, all
    #    live across the back-edge (6 > pool of 5 => at least one spilled
    #    accumulator that must round-trip correctly every iteration), entirely
    #    inside the method body.
    n_iter = 4
    NACC = 6
    s = [i + 1 for i in range(NACC)]
    for _ in range(n_iter):
        s = [(s[i] + (i + 1)) & M for i in range(NACC)]
    loopsum = sum(s) & M
    init = "".join(
        f"        s{i}: uint64 = cast[uint64]({i + 1})\n" for i in range(NACC))
    upd = "".join(
        f"            s{i} = s{i} + cast[uint64]({i + 1})\n" for i in range(NACC))
    fin = " + ".join(f"s{i}" for i in range(NACC))
    body2 = (
        IO
        + "class Loopy:\n"
        + "    tag: uint64\n"
        + "    def __init__(self):\n"
        + "        self.tag = cast[uint64](0)\n"
        + "    def run(self, n: int64) -> uint64:\n"
        + init
        + "        lk: int64 = 0\n"
        + "        while lk < n:\n"
        + upd
        + "            lk = lk + 1\n"
        + f"        return {fin}\n"
        + "def main(argc: int32, argv: Ptr[uint64]) -> int32:\n"
        + "    o: Loopy = Loopy()\n"
        + f"    r: uint64 = o.run(cast[int64]({n_iter}))\n"
        + "    emit3(r)\n"
        + "    return cast[int32](r & cast[uint64](255))\n"
    )
    progs.append(("method_loop_spill", body2,
                  f"{loopsum % 1000:03d}", loopsum & 0xFF))

    return progs


def _run_method_regpressure_corpus():
    """Run the method register-pressure corpus through codegen.ad with --opt and
    assert (a) the method-spilled output is CORRECT vs the oracle, (b) the emitted
    image uses a callee-saved register (which, since only the METHOD has pressure,
    proves gen_method now register-promotes), (c) the OFF image is byte-inert (no
    callee push) and differs from ON, and (d) the --dump-regalloc lane attributes
    the in-register/spilled values to the extra (method) functions it now walks.
    Returns (all_ok, total_inreg, total_spilled, method_regmove_progs)."""
    host = _ad_host()
    all_ok = True
    total_inreg = 0
    total_spilled = 0
    method_max_regs = 0
    method_regmove_progs = 0

    _CALLEE_PUSH = (bytes([0x53]), bytes([0x41, 0x54]), bytes([0x41, 0x55]),
                    bytes([0x41, 0x56]), bytes([0x41, 0x57]))

    def _contains_any(blob, pats):
        return any(p in blob for p in pats)

    for (name, body, exp_out, exp_exit) in _method_regpressure_corpus():
        r = host.run_through_codegen_ad(f"mrp_{name}", body, _AD_WORK, opt=True)
        if r.kind != "ok":
            all_ok = False
            print(f"  [METHOD-REGPRESSURE '{name}'] codegen.ad {r.kind}: "
                  f"{r.detail[:140]}")
            continue
        if r.stdout != exp_out or r.exit != exp_exit:
            all_ok = False
            print(f"  [METHOD-REGPRESSURE '{name}'] MISCOMPILE opt=("
                  f"{r.stdout!r},{r.exit}) oracle=({exp_out!r},{exp_exit})")
            continue
        ra = host.run_regalloc_over_body(f"mrp_{name}", body, _AD_WORK)
        if ra.status != "raok":
            all_ok = False
            print(f"  [METHOD-REGPRESSURE '{name}'] regalloc lane {ra.status}: "
                  f"{ra.detail[:120]}")
            continue
        total_inreg += ra.inreg
        total_spilled += ra.spilled
        method_max_regs = max(method_max_regs, ra.max_regs)

        # MACHINE-CODE proof scoped to the METHOD: only the method exceeds the
        # 5-reg pool (the free helpers have <=2 locals), so a callee-saved push
        # in the ON image necessarily comes from gen_method's promotion. OFF must
        # be byte-inert.
        src = _AD_WORK / f"mrpmc_{name}.ad"
        src.write_text(body)
        d_on = host.run_dump(src, opt=True)
        d_off = host.run_dump(src, opt=False)
        if d_on.status != "ok" or d_off.status != "ok":
            all_ok = False
            print(f"  [METHOD-REGPRESSURE '{name}'] dump status on={d_on.status} "
                  f"off={d_off.status}")
            continue
        on_push = _contains_any(d_on.code, _CALLEE_PUSH)
        off_push = _contains_any(d_off.code, _CALLEE_PUSH)
        if not on_push:
            all_ok = False
            print(f"  [METHOD-REGPRESSURE '{name}'] method body shows NO callee-"
                  f"saved register move under --opt (gen_method not promoting)")
            continue
        if off_push:
            all_ok = False
            print(f"  [METHOD-REGPRESSURE '{name}'] OFF path NOT byte-inert: a "
                  f"callee-saved push with the flag off")
            continue
        if d_on.code == d_off.code:
            all_ok = False
            print(f"  [METHOD-REGPRESSURE '{name}'] --opt did not change the code")
            continue
        method_regmove_progs += 1

    if total_inreg == 0:
        all_ok = False
        print("  [METHOD-REGPRESSURE FAIL] no method value placed in a register")
    # PRESSURE proof: a method must exceed the 5-register callee-saved pool —
    # either by SPILLING (>10 live, exceeds even the expanded pool) OR by using
    # the P3 caller-saved expansion (RA_MAX_REGS > 5 in a call-free method).
    # Before P3 these methods spilled; now the larger pool absorbs the pressure
    # into the caller-saved extension instead, which max_regs>5 demonstrates.
    if total_spilled == 0 and method_max_regs <= 5:
        all_ok = False
        print("  [METHOD-REGPRESSURE FAIL] no method register pressure "
              f"(no spill and RA_MAX_REGS={method_max_regs} <= 5)")
    if method_regmove_progs == 0:
        all_ok = False
        print("  [METHOD-REGPRESSURE FAIL] no method emitted a callee-saved "
              "register move under --opt")
    return (all_ok, total_inreg, total_spilled, method_regmove_progs)


# --------------------------------------------------------------------------
# Differential batch driver for the self-hosted codegen.ad backend.
# --------------------------------------------------------------------------
def _run_ad_codegen_batch(base, args):
    """Run the codegen.ad differential gate over a seeded batch and report
    accept-rate + correctness-rate. Exits NONZERO only on a genuine codegen.ad
    miscompile (a program codegen.ad accepted but got wrong) or a primary
    (python) backend miscompile."""
    ran = 0
    accepted = 0          # codegen.ad compiled it
    correct = 0           # accepted AND matched the oracle
    unsupported = 0       # codegen.ad rejected (out of subset)
    mis = []              # genuine codegen.ad miscompiles
    pymis = []            # python-backend disagreements with the oracle
    errs = []             # tooling/run errors (crash/runfail/ad-error)
    print(f"[fuzz-adcodegen] base_seed={args.seed} count={args.count} "
          f"(self-hosted codegen.ad differential, host-only)")
    for i in range(args.count):
        seed = base + i
        try:
            kind, s, detail, body = check_one(seed)
        except Exception as e:
            print(f"[gentool-bug seed={seed}] {e!r}")
            continue
        ran += 1
        if ADDER_CFG:
            run_cfg_lane(seed, body)
        if kind == "ok":
            accepted += 1; correct += 1
        elif kind == "unsupported":
            unsupported += 1
        elif kind == "differential":
            accepted += 1
            mis.append((s, detail))
            print(f"[MISCOMPILE seed={s}] {detail}")
            WORK.mkdir(parents=True, exist_ok=True)
            (WORK / f"adcodegen_miscompile_{s}.ad").write_text(body)
        elif kind == "py-miscompile":
            pymis.append((s, detail))
            print(f"[PY-MISCOMPILE seed={s}] {detail}")
            WORK.mkdir(parents=True, exist_ok=True)
            (WORK / f"py_miscompile_{s}.ad").write_text(body)
        else:  # crash / runfail / ad-error
            errs.append((kind, s, detail))
            print(f"[{kind} seed={s}] {detail[:160]}")
        if mis and len(mis) >= args.max_fail:
            print(f"[fuzz-adcodegen] reached --max-fail={args.max_fail}")
            break
        if (i + 1) % 500 == 0:
            ar = (accepted / ran * 100) if ran else 0.0
            print(f"[fuzz-adcodegen] ...{i+1}/{args.count} run, "
                  f"accepted={accepted} ({ar:.1f}%), miscompiles={len(mis)}")

    acc_rate = (accepted / ran * 100) if ran else 0.0
    corr_rate = (correct / accepted * 100) if accepted else 0.0
    print("\n===== CODEGEN.AD DIFFERENTIAL REPORT =====")
    print(f"programs run:                 {ran}")
    print(f"codegen.ad accepted:          {accepted}  ({acc_rate:.1f}% of run)")
    print(f"  of accepted, CORRECT:       {correct}  ({corr_rate:.1f}%)")
    print(f"  of accepted, MISCOMPILED:   {len(mis)}")
    print(f"codegen.ad unsupported:       {unsupported}  "
          f"(out of codegen.ad subset -- NOT a failure)")
    print(f"python-backend miscompiles:   {len(pymis)}  (primary-backend bug)")
    print(f"tooling/run errors:           {len(errs)}")
    opt_lane_fail = False
    if ADDER_OPT:
        print(f"--- ADDER_OPT=1 native-optimizer correctness lane ---")
        print(f"  const-folds fired (total):  {_AD_OPT_FOLDS_TOTAL}")
        print(f"  programs with >=1 fold:     {_AD_OPT_PROGS_FOLDED}")
        print(f"  CSE eliminations (total):   {_AD_OPT_CSE_TOTAL}")
        print(f"  programs with >=1 CSE:      {_AD_OPT_PROGS_CSE}")
        print(f"  LICM hoists (total):        {_AD_OPT_LICM_TOTAL}")
        print(f"  programs with >=1 LICM:     {_AD_OPT_PROGS_LICM}")
        print(f"  DCE dead-local removals:    {_AD_OPT_DCE_TOTAL}")
        print(f"  programs with >=1 DCE:      {_AD_OPT_PROGS_DCE}")
        print(f"  const-branch folds (total): {_AD_OPT_CONSTBRANCH_TOTAL}")
        print(f"  programs with >=1 constbr:  {_AD_OPT_PROGS_CONSTBRANCH}")
        print(f"  copy-prop forwards (total): {_AD_OPT_COPYPROP_TOTAL}")
        print(f"  programs with >=1 copyprop: {_AD_OPT_PROGS_COPYPROP}")
        print(f"  (above CORRECT count already asserts opt output == oracle)")
        # The lane only proves anything if the pass DEMONSTRABLY fired. If the
        # whole batch produced zero folds the optimizer wasn't exercised, which
        # is itself a lane failure.
        if accepted > 0 and _AD_OPT_FOLDS_TOTAL == 0:
            opt_lane_fail = True
            print("  [ADDER_OPT FAIL] optimizer never fired across the batch")
        # The fuzz generator emits constant-condition branches (if <const>:) into
        # every pure helper, so the const-branch-folding pass MUST fire across a
        # non-trivial batch; a zero total means the pass regressed / was bypassed.
        if accepted > 0 and _AD_OPT_CONSTBRANCH_TOTAL == 0:
            opt_lane_fail = True
            print("  [ADDER_OPT FAIL] const-branch folding never fired across the batch")
        # The fuzz generator emits a dead pure copy `cpy = <leaf>` whose dest is
        # then read into every pure helper (COPY-PROP bait, observationally inert),
        # so the Phase-9 copy-propagation pass MUST fire across a non-trivial batch;
        # a zero total means the pass regressed / was bypassed.
        if accepted > 0 and _AD_OPT_COPYPROP_TOTAL == 0:
            opt_lane_fail = True
            print("  [ADDER_OPT FAIL] copy propagation never fired across the batch")
        # Phase-2 dedicated CSE corpus: the random batch above rarely emits
        # repeated NON-constant subexpressions, so we run a hand-written corpus
        # of repeated-pure-binop programs through codegen.ad (--opt) and assert
        # (a) the optimized output is correct vs a computed oracle AND (b) the
        # CSE pass demonstrably fired (>=1 elimination across the corpus).
        cse_ok, cse_elims = _run_cse_corpus()
        print(f"--- ADDER_OPT=1 CSE corpus ---")
        print(f"  corpus CSE eliminations:    {cse_elims}")
        if not cse_ok:
            opt_lane_fail = True
            print("  [ADDER_OPT FAIL] CSE corpus miscompiled or never fired")
        # Phase-3 dedicated LICM corpus: hand-written loops with loop-invariant
        # pure subexpressions. Assert (a) optimized output is correct vs a
        # computed oracle (incl. a zero-trip loop and clobbered-leaf cases that
        # would miscompile if the pass over-hoisted) AND (b) the LICM pass
        # demonstrably hoisted (>=1 across the corpus).
        licm_ok, licm_hoists = _run_licm_corpus()
        print(f"--- ADDER_OPT=1 LICM corpus ---")
        print(f"  corpus LICM hoists:         {licm_hoists}")
        if not licm_ok:
            opt_lane_fail = True
            print("  [ADDER_OPT FAIL] LICM corpus miscompiled or never fired")
        # Phase-4 register-pressure corpus: many simultaneously-live scalar
        # locals (> the 5-reg callee-saved pool) + call-crossing + loop-carried
        # spills. Asserts the allocated/spilled output is CORRECT vs the oracle
        # AND that the linear-scan allocator demonstrably used registers and hit
        # real pressure (a spill or full pool).
        rp_ok, rp_inreg, rp_spill, rp_maxregs, rp_regmove = _run_regpressure_corpus()
        print(f"--- ADDER_OPT=1 register-pressure corpus (linear scan) ---")
        print(f"  values kept in registers:   {rp_inreg}")
        print(f"  values spilled to memory:   {rp_spill}")
        print(f"  max regs used in a function:{rp_maxregs}  (pool size 5)")
        print(f"  programs w/ reg-move in code:{rp_regmove}  (machine-code proof)")
        if not rp_ok:
            opt_lane_fail = True
            print("  [ADDER_OPT FAIL] register-pressure corpus miscompiled or "
                  "allocator inert")
        # STORE-THROUGH-ELIMINATION corpus: fully register-promoted plain scalars
        # drop their shadow stack store; soundness programs (scalar-ptr base,
        # for-IV, address-taken, fnptr callee) keep theirs. Asserts correctness
        # vs the oracle (catches a missed slot-read), the lever fired
        # (STOREELIM>0), and is byte-inert OFF.
        st_ok, st_total = _run_storethrough_corpus()
        print(f"--- ADDER_OPT=1 store-through-elimination corpus ---")
        print(f"  write-through stores eliminated: {st_total}")
        if not st_ok:
            opt_lane_fail = True
            print("  [ADDER_OPT FAIL] store-through-elimination corpus miscompiled, "
                  "lever never fired, or OFF not byte-inert")
        # Phase-4 METHOD register-pressure corpus: class methods with more live
        # locals than the 5-reg pool, surrounded by pressure-free free functions.
        # Asserts gen_method now register-promotes (correct under method spilling,
        # a callee-saved move in the emitted method body, OFF byte-inert).
        mrp_ok, mrp_inreg, mrp_spill, mrp_regmove = _run_method_regpressure_corpus()
        print(f"--- ADDER_OPT=1 METHOD register-pressure corpus (gen_method) ---")
        print(f"  method values in registers: {mrp_inreg}")
        print(f"  method values spilled:      {mrp_spill}")
        print(f"  programs w/ method reg-move: {mrp_regmove}  (machine-code proof)")
        if not mrp_ok:
            opt_lane_fail = True
            print("  [ADDER_OPT FAIL] method register-pressure corpus miscompiled "
                  "or gen_method allocator inert")
        # Phase-5 IR-EMIT corpus: programs whose hot expressions lower FULLY into
        # the value IR, so codegen emits them by walking the IR tree (gen_expr_ir)
        # instead of the AST. Asserts (a) correctness vs a computed oracle, (b) the
        # IR emitter demonstrably fired (IREMIT>0, not the AST fallback), (c) the
        # OFF path is byte-inert (IREMIT==0), and (d) ADD constant-tail
        # reassociation reached the machine code (IRREASSOC>0 AND ON image strictly
        # smaller than OFF) — the genuine AST->IR->optimize->emit pipeline.
        ie_ok, ie_total, ie_reassoc = _run_iremit_corpus()
        print(f"--- ADDER_OPT=1 IR-EMIT corpus (Phase-5 IR-consuming backend) ---")
        print(f"  subtrees emitted via IR:    {ie_total}")
        print(f"  ADD reassociations fired:   {ie_reassoc}")
        if not ie_ok:
            opt_lane_fail = True
            print("  [ADDER_OPT FAIL] IR-emit corpus miscompiled, IR path never "
                  "fired, OFF not byte-inert, or reassoc did not reach machine code")
        # Phase-3 INSTRUCTION-SELECTION corpus: array index / pointer arithmetic /
        # memory-operand ALU programs whose element-address computation lowers to a
        # scaled-index `lea` under --opt. Asserts (a) optimized output correct vs an
        # oracle, (b) optimized == --opt-OFF (so the addressing mode is right), (c)
        # the isel pass fired (ISEL>0) and is byte-inert OFF (ISEL==0).
        isel_ok, isel_total = _run_isel_corpus()
        print(f"--- ADDER_OPT=1 ISEL corpus (Phase-3 instruction selection) ---")
        print(f"  scaled-index lea folds:     {isel_total}")
        if not isel_ok:
            opt_lane_fail = True
            print("  [ADDER_OPT FAIL] isel corpus miscompiled, isel never fired, "
                  "or OFF not byte-inert")
        # P1 Phase-1 DESTINATION-SELECTOR corpus: scalar = pure-arith-binop into a
        # register-promoted home computed directly into the register (no %rax
        # round-trip, no shadow store). Asserts (a) correctness vs an oracle for
        # ON and OFF, (b) the routed shapes fired (DESTSEL>0) and fallback shapes
        # (dst-alias, call-in-RHS) did NOT route, (c) byte-inert OFF (DESTSEL==0).
        ds_ok, ds_total = _run_destsel_corpus()
        print(f"--- ADDER_OPT=1 DESTSEL corpus (P1 destination-driven selector) ---")
        print(f"  dest-driven assignments:    {ds_total}")
        if not ds_ok:
            opt_lane_fail = True
            print("  [ADDER_OPT FAIL] destsel corpus miscompiled, dest-selector "
                  "never fired, a fallback shape routed, or OFF not byte-inert")
        # DCE call-argument corpus: a local used ONLY as a 2nd+ call argument was
        # under-counted by DCE (the nd_next operand chain was not walked), so its
        # decl got deleted and codegen aborted (cgfail) under --opt. Asserts each
        # such program compiles + runs correctly ON and OFF, OFF is DCE-inert, and
        # DCE still fires on a genuinely-dead local.
        dca_ok, dca_total = _run_dce_callarg_corpus()
        print(f"--- ADDER_OPT=1 DCE call-arg corpus (2nd+ arg use-count fix) ---")
        print(f"  dead locals reclaimed:      {dca_total}")
        if not dca_ok:
            opt_lane_fail = True
            print("  [ADDER_OPT FAIL] DCE call-arg corpus cgfailed/miscompiled, "
                  "DCE never fired, or OFF not DCE-inert")
        # nd_next SIBLING-CHAIN class guard: values living ONLY in a later operand
        # position (2nd/3rd call args, nested calls in arg position, shadowing
        # params) fed through copy-prop / CSE / LICM, plus the METHOD-CALL barrier
        # load-CSE miscompile (ND_METHOD_CALL must flush a held load). Each must
        # compile + run correctly ON and OFF, ON == OFF == oracle.
        nn_ok, nn_total = _run_ndnext_corpus()
        print(f"--- ADDER_OPT=1 nd_next sibling-chain corpus (whole-class guard) ---")
        print(f"  programs checked ON+OFF:    {nn_total}")
        if not nn_ok:
            opt_lane_fail = True
            print("  [ADDER_OPT FAIL] nd_next corpus miscompiled/cgfailed ON or "
                  "OFF (sibling-chain analysis or method-call barrier regressed)")
        # P1 Phase-2 BASE-HOIST corpus: loop-invariant global-array bases hoisted
        # into a held register (one scaled-index lea off the base per access, no
        # per-iteration `lea g(%rip)`). Asserts (a) correctness vs oracle ON+OFF
        # over multi-dim/negative/mixed-size/impure-index/pointer-base risk shapes,
        # (b) the lever fired (BASEHOIST>0) on the want_fire programs and refused to
        # hoist across a call, (c) byte-inert OFF (BASEHOIST==0).
        bh_ok, bh_total = _run_basehoist_corpus()
        print(f"--- ADDER_OPT=1 BASEHOIST corpus (P1 Phase-2 base residency) ---")
        print(f"  global-array bases hoisted: {bh_total}")
        if not bh_ok:
            opt_lane_fail = True
            print("  [ADDER_OPT FAIL] basehoist corpus miscompiled, lever never "
                  "fired, hoisted across a call, or OFF not byte-inert")
        # P1 Phase-3 STATEMENT-GLUE STORE corpus: augmented accumulators routed
        # into a promoted register home (`s OP= expr`, no slot reload) and indexed
        # stores `arr[i] = <pure-arith binop>` whose RHS is computed dest-driven.
        # Asserts (a) correctness ON+OFF over the historical nested-reinit-accum
        # shape, store-to-aliased-load, signed/unsigned compares, short-circuit
        # conditions, mixed element sizes, and the call/impure-index/float/sub-8
        # FALLBACK shapes, (b) the routed shapes fired (ACCSEL+IDXSTORE>0), (c)
        # byte-inert OFF (both counters 0).
        p3_ok, p3_total = _run_p3store_corpus()
        print(f"--- ADDER_OPT=1 P3STORE corpus (P1 Phase-3 statement-glue stores) ---")
        print(f"  accumulator/indexed stores routed: {p3_total}")
        if not p3_ok:
            opt_lane_fail = True
            print("  [ADDER_OPT FAIL] p3store corpus miscompiled, a store-glue "
                  "lever never fired, a fallback shape routed, or OFF not byte-inert")
        # FLOAT IR-EMIT corpus: float arith/compares (f32/f64/mixed/nested/neg)
        # lowered through the SSE float IR path. Asserts correctness vs an IEEE
        # oracle, the float IR path fired (IREMITFLOAT>0), and the OFF path is
        # byte-inert (IREMITFLOAT==0 and IREMIT==0).
        print("--- ADDER_OPT=1 FLOAT IR-EMIT corpus (SSE float lowering) ---")
        try:
            import iremit_float_check as _flt
            flt_ok = _flt.run()
        except Exception as _e:                       # noqa: BLE001
            flt_ok = False
            print(f"  [ADDER_OPT FAIL] float IR-emit corpus errored: {_e}")
        if not flt_ok:
            opt_lane_fail = True
            print("  [ADDER_OPT FAIL] float IR-emit corpus miscompiled, float IR "
                  "path never fired, or OFF not byte-inert")
    cfg_lane_fail = False
    if ADDER_CFG:
        print(f"--- ADDER_CFG=1 CFG/liveness GROUNDWORK lane (analysis-only) ---")
        print(f"  programs validated:         {_AD_CFG_PROGS}")
        print(f"  functions processed:        {_AD_CFG_FUNCS}")
        print(f"  basic blocks built:         {_AD_CFG_BLOCKS}")
        print(f"  CFG edges:                  {_AD_CFG_EDGES}")
        print(f"  CFG instructions:           {_AD_CFG_INSTS}")
        print(f"  functions skipped (overflow): {_AD_CFG_SKIPPED}")
        # Phase-4 PREREQ: value-level live ranges + alias/may-clobber analysis.
        _avg_len = (_AD_CFG_RANGE_LEN / _AD_CFG_RANGES) if _AD_CFG_RANGES else 0.0
        _pct_prom = (_AD_CFG_PROMOTABLE / _AD_CFG_LOCALS * 100) if _AD_CFG_LOCALS else 0.0
        _pct_clob = (_AD_CFG_CLOBBERABLE / _AD_CFG_LOCALS * 100) if _AD_CFG_LOCALS else 0.0
        print(f"  --- value-level live ranges + alias (Phase-4 PREREQ) ---")
        print(f"  live ranges (total):        {_AD_CFG_RANGES}")
        print(f"  avg interval length:        {_avg_len:.2f}")
        print(f"  max interval length:        {_AD_CFG_RANGE_MAX}")
        print(f"  distinct locals/params:     {_AD_CFG_LOCALS}")
        print(f"  register-promotable:        {_AD_CFG_PROMOTABLE}  ({_pct_prom:.1f}%)")
        print(f"  clobberable (escaped):      {_AD_CFG_CLOBBERABLE}  ({_pct_clob:.1f}%)")
        print(f"  broken-invariant programs:  {len(_AD_CFG_FAILS)}")
        # The lane proves something only if it actually built CFGs. An all-empty
        # run (no function processed) is itself a lane failure.
        if _AD_CFG_PROGS > 0 and _AD_CFG_FUNCS == 0:
            cfg_lane_fail = True
            print("  [ADDER_CFG FAIL] CFG builder never processed a function")
        if _AD_CFG_FAILS:
            cfg_lane_fail = True
            for (s, detail) in _AD_CFG_FAILS[:10]:
                print(f"  [CFG INVARIANT BROKEN] seed={s}: {detail[:160]}")
                print(f"        repro: ADDER_FUZZ_DIFF_TARGET=ad-codegen "
                      f"ADDER_CFG=1 python3 tests/fuzz/adder_fuzzer.py --repro {s}")
    for (s, detail) in mis[:10]:
        print(f"  [miscompile] seed={s}: {detail[:160]}")
        print(f"        repro: ADDER_FUZZ_DIFF_TARGET=ad-codegen "
              f"python3 tests/fuzz/adder_fuzzer.py --repro {s}")
    for (s, detail) in pymis[:10]:
        print(f"  [py-miscompile] seed={s}: {detail[:160]}")
    print("==========================================")
    # Fail on a genuine miscompile (codegen.ad OR python). In the ADDER_OPT=1
    # lane a miscompile means the OPTIMIZED output diverged from the oracle;
    # also fail if the optimizer never fired (lane didn't actually exercise it).
    return 1 if (mis or pymis or opt_lane_fail or cfg_lane_fail) else 0


# --------------------------------------------------------------------------
# Main batch driver.
# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description="Adder x86_64 backend fuzzer")
    ap.add_argument("--count", type=int, default=2000)
    ap.add_argument("--seed", type=int, default=1, help="base RNG seed")
    ap.add_argument("--repro", type=int, default=None,
                    help="re-run a single program by its absolute seed")
    ap.add_argument("--emit", type=int, default=None,
                    help="print the source of one program by its seed and exit")
    ap.add_argument("--max-fail", type=int, default=20,
                    help="stop after this many distinct failures")
    ap.add_argument("--diff-target", default=os.environ.get(
                        "ADDER_FUZZ_DIFF_TARGET"),
                    help="SCAFFOLD: also run each program through this second "
                         "--target= (e.g. a future 2nd backend) and report a "
                         "diff against it; the predicted-output oracle remains "
                         "the primary check. Default: off.")
    ap.add_argument("--opt", type=int, default=None, choices=[0, 1, 2],
                    help="compile each program at this -O level (0 = trusted "
                         "single-pass, 1 = peephole optimizer, 2 = + stack-slot "
                         "register promotion). The predicted-output oracle "
                         "validates the chosen level directly. "
                         "Default: ADDER_FUZZ_OPT or 0.")
    ap.add_argument("--ad-codegen", action="store_true",
                    default=(os.environ.get("ADDER_FUZZ_DIFF_TARGET")
                             == "ad-codegen"),
                    help="DIFFERENTIAL: also compile+run each program through "
                         "the self-hosted codegen.ad backend ON THE HOST (no "
                         "QEMU) and compare against the Python backend / oracle. "
                         "Programs use the codegen.ad-supported subset (no 2-D "
                         "array global). Reports accept-rate + correctness-rate; "
                         "fails ONLY on a genuine codegen.ad miscompile.")
    args = ap.parse_args()

    global DIFF_TARGET, OPT_LEVEL, AD_CODEGEN
    DIFF_TARGET = args.diff_target
    AD_CODEGEN = args.ad_codegen
    if args.opt is not None:
        OPT_LEVEL = args.opt

    if args.emit is not None:
        p, body = render_program(args.emit, subset=AD_CODEGEN)
        sys.stdout.write(body)
        sys.stderr.write(f"\n# expected stdout={p.expected_stdout} "
                         f"exit={p.expected_exit}\n")
        return 0

    if args.repro is not None:
        kind, seed, detail, body = check_one(args.repro)
        WORK.mkdir(parents=True, exist_ok=True)
        (WORK / f"repro_{seed}.ad").write_text(body)
        print(f"[repro {seed}] {kind}: {detail}")
        print(f"  source saved to {WORK / f'repro_{seed}.ad'}")
        return 0 if kind == "ok" else 1

    base = args.seed * 1_000_003

    if AD_CODEGEN:
        return _run_ad_codegen_batch(base, args)

    fails = {"miscompile": [], "crash": [], "runfail": []}
    ran = 0
    print(f"[fuzz] base_seed={args.seed} count={args.count}")
    for i in range(args.count):
        seed = base + i
        try:
            kind, s, detail, body = check_one(seed)
        except Exception as e:
            print(f"[gentool-bug seed={seed}] {e!r}")
            continue
        ran += 1
        if kind != "ok":
            fails.setdefault(kind, []).append((s, detail))
            print(f"[{kind} seed={s}] {detail}")
            WORK.mkdir(parents=True, exist_ok=True)
            (WORK / f"fail_{kind}_{s}.ad").write_text(body)
            if sum(len(v) for v in fails.values()) >= args.max_fail:
                print(f"[fuzz] reached --max-fail={args.max_fail}, stopping")
                break
        if (i + 1) % 1000 == 0:
            tf = sum(len(v) for v in fails.values())
            print(f"[fuzz] ...{i+1}/{args.count} run, {tf} failures so far")

    print("\n========== FUZZ REPORT ==========")
    print(f"programs run:        {ran}")
    print(f"miscompiles:         {len(fails['miscompile'])}")
    print(f"compiler crashes:    {len(fails['crash'])}")
    print(f"runtime failures:    {len(fails['runfail'])}")
    # any extra kinds (e.g. differential) get reported too.
    extra = [k for k in fails if k not in ("miscompile", "crash", "runfail")
             and fails[k]]
    for k in extra:
        print(f"{k+':':<20} {len(fails[k])}")
    for kind in ("miscompile", "crash", "runfail", *extra):
        for (s, detail) in fails[kind][:10]:
            print(f"  [{kind}] seed={s}: {detail[:160]}")
            print(f"           repro: python3 tests/fuzz/adder_fuzzer.py "
                  f"--emit {s}")
    print("=================================")
    return 1 if any(fails.values()) else 0


if __name__ == "__main__":
    sys.exit(main())
