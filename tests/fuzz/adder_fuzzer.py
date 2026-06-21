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
    def __init__(self, seed):
        self.seed = seed
        self.rng = random.Random(seed)
        self.lines = []
        self.acc = 0                  # oracle: running uint64 accumulator
        self.helpers = []             # list of (name, py_callable, n_args)

    def _acc_add(self, v):
        self.acc = (self.acc + (v & umask(64))) & umask(64)

    def emit(self, s):
        self.lines.append(s)

    def build(self):
        rng = self.rng
        # ----- globals: 2-D array + one array per store width ----------------
        rows = rng.randint(2, 4)
        cols = rng.randint(2, 4)
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

        self._gen_grid_traffic(env)
        self._gen_store_traffic(env)
        self._gen_scalar_global_traffic(env)
        self._gen_loop(env)
        self._gen_helper_calls(env)

        self.emit(f"    print_u64(g_accum)")
        self.emit(f"    return cast[int32](cast[uint64](g_accum) & cast[uint64](255))")

        body = PRELUDE + "\n" + "\n".join(self.lines) + "\n"
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
            # read back widened to uint64 via the global's declared signedness
            self._fold_value(f"cast[uint64]({name})", U64.wrap(stored))

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


def render_program(seed):
    p = Program(seed)
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


def check_one(seed):
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
    ap.add_argument("--opt", type=int, default=None, choices=[0, 1],
                    help="compile each program at this -O level (0 = trusted "
                         "single-pass, 1 = peephole optimizer). The predicted-"
                         "output oracle validates the chosen level directly. "
                         "Default: ADDER_FUZZ_OPT or 0.")
    args = ap.parse_args()

    global DIFF_TARGET, OPT_LEVEL
    DIFF_TARGET = args.diff_target
    if args.opt is not None:
        OPT_LEVEL = args.opt

    if args.emit is not None:
        p, body = render_program(args.emit)
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
