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
        d = self.rng.randint(1, 9)            # nonzero divisor (avoid /0 fault)
        op = self.rng.choice(["/", "%"])
        # The divisor is a typed literal cast[typ](d): its get_expr_type is typ.
        b = TV(f"cast[{typ.name}]({d})", _to_reg(typ.wrap(d)), typ, gt=typ)
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
        self.emit("")

        # ----- helper functions ---------------------------------------------
        for h in range(rng.randint(1, 2)):
            self._build_helper(h)
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
        self._gen_scalar_global_traffic(env)
        self._gen_struct_traffic(env)     # struct locals: member store/read
        self._gen_class_traffic(env)      # class construction + method dispatch
        self._gen_multibase_traffic(env)  # multi-base inherited-method dispatch
        self._gen_for_range_traffic(env)  # for v in range(...)
        self._gen_for_array_traffic(env)  # for v in <array global>
        self._gen_do_while_traffic(env)   # do/while
        self._gen_float_traffic(env)      # scalar SSE float32/float64
        self._gen_loop(env)
        self._gen_short_circuit_traffic(env)  # logical and/or short-circuit
        self._gen_helper_calls(env)

        self.emit(f"    print_u64(g_accum)")
        self.emit(f"    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))")

        body = (PRELUDE + "\n"
                + "\n".join(self.toplevel) + "\n"
                + "\n".join(self.lines) + "\n")
        self.expected_stdout = str(self.acc & umask(64))
        self.expected_exit = self.acc & 0xFF
        return body

    # ---- helper: pure int function f(a,b[,c]) -> int64 -----------------------
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
        thr = rng.randint(0, 50)
        self.emit(f"    if r > cast[int64]({thr}):")
        self.emit(f"        r = r - cast[int64]({thr})")
        self.emit("    return r")

        def pyfn(args, recipe=recipe, thr=thr):
            r = I64.wrap(self._recipe_eval(recipe, args))
            if r > thr:
                r = I64.wrap(r - thr)
            return r
        self.helpers.append((name, pyfn, nargs))

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


def _ad_host():
    global _AD_HOST, _AD_WORK
    if _AD_HOST is None:
        import importlib
        _AD_HOST = importlib.import_module("ad_codegen_host")
        _AD_WORK = WORK / "ad_codegen"
    return _AD_HOST


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
        print(f"  (above CORRECT count already asserts opt output == oracle)")
        # The lane only proves anything if the pass DEMONSTRABLY fired. If the
        # whole batch produced zero folds the optimizer wasn't exercised, which
        # is itself a lane failure.
        if accepted > 0 and _AD_OPT_FOLDS_TOTAL == 0:
            opt_lane_fail = True
            print("  [ADDER_OPT FAIL] optimizer never fired across the batch")
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
    return 1 if (mis or pymis or opt_lane_fail) else 0


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
