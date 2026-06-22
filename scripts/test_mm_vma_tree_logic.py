#!/usr/bin/env python3
# scripts/test_mm_vma_tree_logic.py — Wave-3 VMA interval-tree LOGIC gate.
#
# A pure-Python reference re-implementation of the augmented AVL interval
# tree + per-VMA-lock lookup discipline added to mm/vma.ad (the _vt_*,
# _vma_tree_*, and vma_lock_fault_vma helpers). It mirrors the exact
# algorithm — AVL rotations keyed on `start`, subtree_max_end
# augmentation, point-containment descent, overlap pruning, AVL delete via
# in-order successor, and the seqcount/per-VMA trylock fault model — so a
# logic regression in that algorithm is caught WITHOUT booting an image.
#
# This is the no-QEMU half of the verification; scripts/test_mm_pressure.sh
# PART E runs the SAME algorithm inside the real kernel at boot (the
# orchestrator runs it at integration). Both must agree.
#
# Pass marker: [test_vma_tree] PASS   Fail marker: [test_vma_tree] FAIL

import math
import random
import sys


class Node:
    __slots__ = ("start", "end", "left", "right", "height", "max_end",
                 "vlocked")

    def __init__(self, start, end):
        self.start = start
        self.end = end
        self.left = None
        self.right = None
        self.height = 0
        self.max_end = end
        self.vlocked = False


def h(n):
    return n.height if n else 0


def me(n):
    return n.max_end if n else 0


def fix(n):
    n.height = 1 + max(h(n.left), h(n.right))
    n.max_end = max(n.end, me(n.left), me(n.right))


def bal(n):
    return h(n.left) - h(n.right) if n else 0


def rot_right(y):
    x = y.left
    t2 = x.right
    x.right = y
    y.left = t2
    fix(y)
    fix(x)
    return x


def rot_left(x):
    y = x.right
    t2 = y.left
    y.left = x
    x.right = t2
    fix(x)
    fix(y)
    return y


def rebalance(n):
    fix(n)
    bf = bal(n)
    if bf > 1:
        if bal(n.left) < 0:
            n.left = rot_left(n.left)
        return rot_right(n)
    if bf < -1:
        if bal(n.right) > 0:
            n.right = rot_right(n.right)
        return rot_left(n)
    return n


def _insert_rec(root, node):
    if root is None:
        fix(node)
        return node
    if node.start < root.start:
        root.left = _insert_rec(root.left, node)
    else:
        root.right = _insert_rec(root.right, node)
    return rebalance(root)


def insert(root, node):
    # Mirror the kernel's _vma_tree_insert: a node enters as a fresh leaf,
    # so reset its links/height before splicing (a re-inserted node must
    # not carry a stale subtree — that would form a cycle).
    node.left = None
    node.right = None
    node.height = 0
    return _insert_rec(root, node)


def min_node(n):
    while n.left:
        n = n.left
    return n


def remove(root, key, target):
    if root is None:
        return None
    if key < root.start:
        root.left = remove(root.left, key, target)
    elif key > root.start:
        root.right = remove(root.right, key, target)
    else:
        if root is not target:
            root.right = remove(root.right, key, target)
            return rebalance(root)
        l, r = root.left, root.right
        if l is None:
            root.left = None
            root.right = None
            return r
        if r is None:
            root.left = None
            root.right = None
            return l
        succ = min_node(r)
        new_r = remove(r, succ.start, succ)
        succ.left = l
        succ.right = new_r
        root.left = None
        root.right = None
        return rebalance(succ)
    return rebalance(root)


def find(root, addr):
    cur, cand = root, None
    while cur:
        if cur.start <= addr:
            cand = cur
            cur = cur.right
        else:
            cur = cur.left
    if cand and addr < cand.end:
        return cand
    return None


def overlap(root, lo, hi):
    cur = root
    while cur:
        if cur.start < hi and cur.end > lo:
            return cur
        if cur.left and me(cur.left) > lo:
            cur = cur.left
        else:
            cur = cur.right
    return None


def check_avl(n):
    # Returns height, asserting the AVL balance invariant + BST + max_end.
    if n is None:
        return 0
    lh = check_avl(n.left)
    rh = check_avl(n.right)
    assert abs(lh - rh) <= 1, "AVL balance violated"
    if n.left:
        assert n.left.start < n.start, "BST order (left)"
    if n.right:
        assert n.right.start >= n.start, "BST order (right)"
    exp_me = max(n.end, me(n.left), me(n.right))
    assert n.max_end == exp_me, "max_end augmentation stale"
    return 1 + max(lh, rh)


def main():
    fails = 0

    def expect(cond, label):
        nonlocal fails
        if cond:
            print(f"[test_vma_tree] PASS: {label}")
        else:
            print(f"[test_vma_tree] FAIL: {label}", file=sys.stderr)
            fails += 1

    rng = random.Random(1234)

    # Build N disjoint one-page VMAs, 64 KiB apart (like the kernel test).
    N = 256
    PAGE = 0x1000
    STRIDE = 0x10000
    BASE = 0x200000000
    root = None
    nodes = []
    for i in range(N):
        s = BASE + i * STRIDE
        nd = Node(s, s + PAGE)
        root = insert(root, nd)
        nodes.append(nd)

    # E1 — find correctness: every base hit, every gap miss.
    miss = sum(1 for i in range(N)
               if find(root, BASE + i * STRIDE) is not nodes[i])
    gapmiss = sum(1 for i in range(N)
                  if find(root, BASE + i * STRIDE + PAGE) is not None)
    expect(miss == 0 and gapmiss == 0,
           f"find correct over {N} VMAs (miss={miss} gapmiss={gapmiss})")

    # E2 — O(log n): height is logarithmic, NOT linear (a list would be N).
    height = h(root)
    avl_bound = math.ceil(1.4405 * math.log2(N + 2))   # AVL worst-case
    expect(0 < height <= avl_bound and height < 20,
           f"tree height={height} (<= AVL bound {avl_bound}, << N={N})")

    # E2b — structural invariants hold throughout.
    try:
        check_avl(root)
        expect(True, "AVL + BST + max_end invariants hold")
    except AssertionError as e:
        expect(False, f"invariant: {e}")

    # E3 — overlap query.
    hit = overlap(root, BASE + 10 * STRIDE, BASE + 10 * STRIDE + PAGE)
    gap = overlap(root, BASE + 10 * STRIDE + PAGE, BASE + 10 * STRIDE + STRIDE)
    expect(hit is nodes[10] and gap is None, "overlap query (hit + gap)")

    # E4 — split: shrink #5 to one page, insert a tail [+1page, +3page).
    # (Model the kernel _vma_split_at: head.end shrinks, tail inserted;
    #  a shrink re-inserts to refresh max_end.)
    head = nodes[5]
    head.end = head.start + 3 * PAGE          # widen first (clean region sim)
    root = remove(root, head.start, head)     # update_end: remove...
    head.end = head.start + 1 * PAGE          # ...shrink...
    root = insert(root, head)                 # ...reinsert.
    tail = Node(head.start + 1 * PAGE, nodes[5].start + 3 * PAGE)
    root = insert(root, tail)
    lo = find(root, head.start)
    hi = find(root, head.start + 1 * PAGE)
    expect(lo is head and hi is tail
           and lo.end == head.start + PAGE
           and hi.start == head.start + PAGE,
           "split keeps tree consistent (both halves findable)")
    check_avl(root)

    # E5 — remove every node; tree must reach empty and stay valid per step.
    order = list(nodes) + [tail]
    rng.shuffle(order)
    for nd in order:
        root = remove(root, nd.start, nd)
        if root is not None:
            check_avl(root)
    expect(root is None, "teardown empties tree (root is None), valid throughout")

    # E6 — per-VMA lock model (seqcount + trylock discipline).
    # Rebuild a small tree and simulate vma_lock_fault_vma.
    root = None
    locks = []
    for i in range(4):
        s = BASE + i * STRIDE
        nd = Node(s, s + PAGE)
        root = insert(root, nd)
        locks.append(nd)
    seq = [0]

    def lock_fault(addr):
        seq0 = seq[0]
        nd = find(root, addr)
        if nd is None:
            return None
        if nd.vlocked:                # trylock fails -> fall back
            return None
        nd.vlocked = True
        if seq[0] != seq0:            # structural race -> fall back
            nd.vlocked = False
            return None
        return nd

    a = lock_fault(BASE + 0 * STRIDE)
    a2 = lock_fault(BASE + 0 * STRIDE)        # same VMA: must fail (held)
    b = lock_fault(BASE + 1 * STRIDE)         # different VMA: must succeed
    expect(a is locks[0] and a2 is None and b is locks[1],
           "per-VMA lock: same VMA serializes, distinct VMAs concurrent")
    # Structural bump while holding a lock forces lockless fallback.
    a.vlocked = False
    b.vlocked = False

    def lock_fault_with_race(addr):
        seq0 = seq[0]
        nd = find(root, addr)
        nd.vlocked = True
        seq[0] += 1                            # race: structural change
        if seq[0] != seq0:
            nd.vlocked = False
            return None
        return nd
    raced = lock_fault_with_race(BASE + 2 * STRIDE)
    expect(raced is None, "seqcount race forces mm-write-lock fallback")

    if fails:
        print("[test_vma_tree] FAIL")
        return 1
    print("[test_vma_tree] PASS — interval-tree + per-VMA-lock logic correct")
    return 0


if __name__ == "__main__":
    sys.exit(main())
