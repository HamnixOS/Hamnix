"""Compile-time affine (move-only) analysis for `Own[T]` handles.

Roadmap increment 5 (Tier B): a lightweight, per-function flow analysis that
tracks whether each `own` binding is LIVE or has been MOVED. Using a moved-from
binding is a compile error ("use after move"); an explicit `drop(x)` moves x, so
a second `drop(x)` / use is caught as a double-free.

ZERO runtime cost: this pass emits NOTHING. `Own[T]` strips to the inner `T` in
the parser, so an `own` binding is byte-identical to a plain `T`. Non-`own` code
is completely unaffected — the pass only inspects functions that declare at least
one `own` binding (param or local), so the entire existing kernel/userland corpus
is a no-op here.

Surface syntax:
    let/binding:  x: Own[Ptr[Foo]] = make_foo()
    parameter:    def consume(h: Own[Ptr[Foo]]): ...

Move rules (a bare `own` identifier is MOVED when it appears as):
  * a call/method-call ARGUMENT passed by value:  consume(x)   / drop(x)
  * the RHS of a binding/assignment:              y = x        / z: T = x
  * a return value:                               return x
  * an element of a tuple/list in any of the above move positions.
To BORROW instead of move, pass the address: `foo(&x)` reads x without moving it
(any non-bare-identifier form — `&x`, `x.f`, `x + 0` — is a read, not a move).

Reading a MOVED binding in ANY position is a "use after move" error.

Conditional moves (stated rule): after an `if`/`match`, a binding is considered
MOVED if it was moved on ANY branch (conservative — this can only reject more, it
never lets a real use-after-move through). Re-assigning a moved binding revives
it (LIVE again). Moving an outer `own` binding inside a loop body is rejected
(it would double-move across iterations).

Opt-out: `unsafe:` blocks and `@unsafe` functions are NOT analysed (the escape
hatch), matching how they relax the runtime safety checks.

Auto-drop insertion (drop() at scope exit for an un-moved `own` binding) is
DEFERRED — see docs/adder_language_roadmap.md. This pass delivers the
high-value core: move / use-after-move errors + explicit-drop double-free.
"""

from . import ast_nodes as ast


class AffineError(Exception):
    """Raised on a use-after-move / double-free of an `own` binding."""
    pass


def _loc(span):
    if span is None:
        return "<unknown>"
    return f"{span.filename}:{span.start_line}"


class _FnChecker:
    """Per-function affine flow analysis.

    `moved` maps an own-binding name -> the Span where it was moved (or None if
    LIVE). `own_names` is the set of names currently known to be `own`.
    """

    def __init__(self, fname):
        self.fname = fname
        self.own_names = set()
        self.moved = {}   # name -> move-site span (present => MOVED)

    # ---- expression walk -------------------------------------------------
    def walk_expr(self, e, move_ctx):
        """Walk an expression. `move_ctx` True => a bare own Identifier here is
        MOVED; otherwise it is a read (which still errors if already moved)."""
        if e is None:
            return
        t = type(e).__name__

        if t == "Identifier":
            if e.name in self.own_names:
                if e.name in self.moved:
                    raise AffineError(
                        f"use after move: `own` binding '{e.name}' used at "
                        f"{_loc(e.span)} was already moved at "
                        f"{_loc(self.moved[e.name])}")
                if move_ctx:
                    self.moved[e.name] = e.span
            return

        if t == "CallExpr":
            self.walk_expr(e.func, False)
            for a in e.args:
                self.walk_expr(a, True)   # pass-by-value => move
            for a in getattr(e, "kwargs", {}).values():
                self.walk_expr(a, True)
            return

        if t == "MethodCallExpr":
            self.walk_expr(e.obj, False)  # receiver is a borrow
            for a in e.args:
                self.walk_expr(a, True)
            return

        if t == "BinaryExpr":
            self.walk_expr(e.left, False)
            self.walk_expr(e.right, False)
            return
        if t == "UnaryExpr":
            # `&x` / `-x` / `not x` — a read of the operand, never a move.
            self.walk_expr(e.operand, False)
            return
        if t == "IndexExpr":
            self.walk_expr(e.obj, False)
            self.walk_expr(e.index, False)
            return
        if t == "SliceExpr":
            self.walk_expr(e.obj, False)
            self.walk_expr(e.start, False)
            self.walk_expr(e.end, False)
            self.walk_expr(e.step, False)
            return
        if t == "MemberExpr":
            self.walk_expr(e.obj, False)  # x.field is a read of x
            return
        if t in ("TupleLiteral", "ListLiteral"):
            for el in e.elements:
                self.walk_expr(el, move_ctx)  # inherit: tuple in move-pos moves
            return
        if t == "DictLiteral":
            for k, v in e.pairs:
                self.walk_expr(k, False)
                self.walk_expr(v, False)
            return
        if t == "ConditionalExpr":
            # cond ? a : b — condition is a read; the two arms inherit ctx and
            # are alternatives (merge conservatively).
            self.walk_expr(e.condition, False)
            base = dict(self.moved)
            self.walk_expr(e.then_expr, move_ctx)
            after_then = dict(self.moved)
            self.moved = dict(base)
            self.walk_expr(e.else_expr, move_ctx)
            for k, v in after_then.items():
                self.moved.setdefault(k, v)
            return
        if t == "CastExpr":
            self.walk_expr(e.expr, move_ctx)
            return
        if t == "UnwrapExpr":
            self.walk_expr(e.expr, False)
            return
        if t == "TryExpr":
            self.walk_expr(e.expr, False)
            return
        if t == "WalrusExpr":
            self.walk_expr(e.value, False)
            return
        if t == "SizeOfExpr":
            return
        if t == "StructInitExpr":
            for v in e.fields.values():
                self.walk_expr(v, False)
            return

        # Fallthrough: generically read any Expr-typed attributes so we never
        # miss a use-after-move in an un-enumerated node shape.
        for attr in ("obj", "expr", "value", "left", "right", "operand",
                     "func", "condition", "index"):
            sub = getattr(e, attr, None)
            if _is_expr(sub):
                self.walk_expr(sub, False)
        for attr in ("args", "elements"):
            seq = getattr(e, attr, None)
            if isinstance(seq, list):
                for it in seq:
                    if _is_expr(it):
                        self.walk_expr(it, False)

    # ---- statement walk --------------------------------------------------
    def walk_stmts(self, stmts):
        for s in stmts:
            self.walk_stmt(s)

    def walk_stmt(self, s):
        t = type(s).__name__

        if t == "VarDecl":
            if s.value is not None:
                self.walk_expr(s.value, True)   # RHS moves a bare own id
            if getattr(s, "is_own", False):
                # (Re)introduce an own binding — LIVE.
                self.own_names.add(s.name)
                self.moved.pop(s.name, None)
            elif s.name in self.own_names:
                # A plain re-decl of a name that was own: it is being rebound to
                # a non-own value; keep it tracked but LIVE.
                self.moved.pop(s.name, None)
            return

        if t == "Assignment":
            self.walk_expr(s.value, True)
            tgt = s.target
            if type(tgt).__name__ == "Identifier":
                if tgt.name in self.own_names:
                    # Reassigning revives the binding (LIVE again).
                    self.moved.pop(tgt.name, None)
            else:
                # x.field = ... / arr[i] = ... — the target is read (borrow).
                self.walk_expr(tgt, False)
            return

        if t == "ExprStmt":
            self.walk_expr(s.expr, False)   # a bare call moves its own args
            return

        if t == "ReturnStmt":
            self.walk_expr(s.value, True)   # returning a bare own id moves out
            return

        if t == "IfStmt":
            self.walk_expr(s.condition, False)
            base = dict(self.moved)
            branch_states = []
            self.moved = dict(base)
            self.walk_stmts(s.then_body)
            branch_states.append(self.moved)
            for cond, body in s.elif_branches:
                self.moved = dict(base)
                self.walk_expr(cond, False)
                self.walk_stmts(body)
                branch_states.append(self.moved)
            if s.else_body is not None:
                self.moved = dict(base)
                self.walk_stmts(s.else_body)
                branch_states.append(self.moved)
            else:
                branch_states.append(dict(base))  # fallthrough path
            # Conservative merge: moved-if-moved-on-any-branch.
            merged = dict(base)
            for st in branch_states:
                for k, v in st.items():
                    merged.setdefault(k, v)
            self.moved = merged
            return

        if t in ("WhileStmt", "DoWhileStmt"):
            self.walk_expr(s.condition, False)
            entry_live = self.own_names - set(self.moved)
            self.walk_stmts(s.body)
            self._check_loop_moves(entry_live, s.span)
            return

        if t in ("ForStmt", "ForUnpackStmt"):
            self.walk_expr(s.iterable, False)
            entry_live = self.own_names - set(self.moved)
            self.walk_stmts(s.body)
            self._check_loop_moves(entry_live, s.span)
            return

        if t == "DeferStmt":
            # A deferred statement runs at scope exit, not now. Check its reads
            # against the current state but do NOT apply its moves (they happen
            # later; this avoids false "use after move" on the deferred body).
            saved = dict(self.moved)
            self.walk_stmt(s.stmt)
            self.moved = saved
            return

        if t == "UnsafeStmt":
            # Escape hatch: the affine check is relaxed inside `unsafe:`.
            return

        if t == "WithStmt":
            for item in s.items:
                self.walk_expr(item.context, False)
            self.walk_stmts(s.body)
            return

        if t == "TryStmt":
            self.walk_stmts(s.body)
            for handler in getattr(s, "handlers", []):
                self.walk_stmts(handler.body if hasattr(handler, "body") else [])
            if getattr(s, "finally_body", None):
                self.walk_stmts(s.finally_body)
            return

        if t == "MatchStmt":
            self.walk_expr(s.subject, False)
            base = dict(self.moved)
            branch_states = []
            for arm in s.arms:
                self.moved = dict(base)
                self.walk_stmts(arm.body)
                branch_states.append(self.moved)
            merged = dict(base)
            for st in branch_states:
                for k, v in st.items():
                    merged.setdefault(k, v)
            self.moved = merged
            return

        if t == "RaiseStmt":
            self.walk_expr(getattr(s, "exception", None), False)
            return
        if t == "AssertStmt":
            self.walk_expr(s.condition, False)
            self.walk_expr(s.message, False)
            return
        if t == "YieldStmt":
            self.walk_expr(getattr(s, "value", None), False)
            return
        # BreakStmt / ContinueStmt / PassStmt / GlobalStmt: nothing to track.
        return

    def _check_loop_moves(self, entry_live, span):
        for name in entry_live:
            if name in self.moved:
                raise AffineError(
                    f"`own` binding '{name}' moved inside a loop at "
                    f"{_loc(span)} (would double-move across iterations); move "
                    f"it out of the loop or re-bind it each iteration")

    def run(self, params, body):
        for p in params:
            if getattr(p, "is_own", False):
                self.own_names.add(p.name)
        self.walk_stmts(body)


def _is_expr(x):
    if x is None:
        return False
    return type(x).__name__ in _EXPR_NAMES


_EXPR_NAMES = {
    "IntLiteral", "FloatLiteral", "StringLiteral", "FStringLiteral",
    "CharLiteral", "BoolLiteral", "NoneLiteral", "Identifier", "BinaryExpr",
    "UnaryExpr", "CallExpr", "MethodCallExpr", "IndexExpr", "SliceExpr",
    "MemberExpr", "ListLiteral", "DictLiteral", "TupleLiteral",
    "ListComprehension", "ConditionalExpr", "LambdaExpr", "SizeOfExpr",
    "CastExpr", "AsmExpr", "ContainerOfExpr", "WalrusExpr", "TryExpr",
    "UnwrapExpr", "SliceNewExpr", "StructInitExpr",
}


def _fn_has_own(fn):
    """Cheap gate: only analyse functions that actually use `own`."""
    for p in fn.params:
        if getattr(p, "is_own", False):
            return True
    return _stmts_have_own(fn.body)


def _stmts_have_own(stmts):
    for s in stmts:
        t = type(s).__name__
        if t == "VarDecl" and getattr(s, "is_own", False):
            return True
        for attr in ("body", "then_body", "else_body", "finally_body"):
            sub = getattr(s, attr, None)
            if isinstance(sub, list) and _stmts_have_own(sub):
                return True
        for _, b in getattr(s, "elif_branches", []) or []:
            if _stmts_have_own(b):
                return True
        for arm in getattr(s, "arms", []) or []:
            if _stmts_have_own(getattr(arm, "body", [])):
                return True
        if t == "DeferStmt" and _stmts_have_own([s.stmt]):
            return True
    return False


def _check_function(fn):
    if fn is None:
        return
    if "unsafe" in getattr(fn, "decorators", []):
        return   # @unsafe relaxes the affine check for the whole body
    if not _fn_has_own(fn):
        return   # byte-inert: non-own functions are never inspected
    _FnChecker(fn.name).run(fn.params, fn.body)


def check_affine(program):
    """Run the affine move-check over a whole program. Raises AffineError on the
    first use-after-move / double-free. A no-op for any program with no `own`."""
    for decl in program.declarations:
        t = type(decl).__name__
        if t == "FunctionDef":
            _check_function(decl)
        elif t == "ClassDef":
            for m in decl.methods:
                _check_function(m)
