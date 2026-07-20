# hambrowse JS string pool GC — Phase 4 (shipped) + compaction plan (deferred)

## What shipped (Phase 4): non-moving string-id reclamation

`lib/web/js/{state,value,gc,api}.ad` now reclaim dead **string IDs** with a
stop-the-world mark-sweep that mirrors the value (Phase 1) and env (Phase 3)
collectors. It lifts the `MAX_STR = 200000` id-table ceiling — the #1 remaining
memory wall (string-heavy JS exhausted at ~200k allocations).

Key property: **NON-MOVING**. Only the id table (`st_off`/`st_len`) is reclaimed;
`sp_buf` bytes are never moved or freed. A reclaimed id's bytes are orphaned (a
bounded leak). This is what makes it provably safe in one pass — see below.

* **Trigger** — at `str_new`/`bld_end` entry only, gated on `gc_disabled == 0`
  and `n_strs >= str_hi_water` (default 80% of `MAX_STR`, so programs that fit
  the table today never trigger and stay byte-for-byte identical). Never at
  `mk_val` (which would race the `h = mk_val(); v_ref[h] = sid` window in
  `v_string_id`, where the just-built sid is momentarily un-rooted).
* **Roots** (wholesale, over-approximate = leak-not-free): `v_ref` of every
  `TAG_STR` value cell; `p_key`; `b_name`; the permanent AST fields
  `n_str`/`n_a`/`n_b`/`n_c`/`n_d`; `tk_str`/`tk_str2`; `mod_spec`; `fx_*`;
  `obj_p_a`/`obj_p_b`; `ctl_label`/`pending_label`.
* **Transients** — every string/array/regex/object builtin already runs under
  `gc_disabled > 0`, so a collection can never fire while a builtin holds an
  un-rooted sid in a native local. Core build helpers keep their operands live as
  `TAG_STR` value handles or AST `n_str`.
* **Value coupling** — a string id stays marked while any value cell references
  it, so a string is only reclaimable once its value cell is swept. An
  *ineffective* string collection therefore lowers `gc_hi_water` so the next
  `mk_val` (a proven-safe value-GC point) sweeps the value arena, after which the
  next string collection reclaims the now-unpinned ids. The value collector is
  **never** run from the string-allocation site (an unpinned value transient
  could be live across it).

### Measured effect
* Id table (`MAX_STR = 200000`) ceiling **lifted**: a manufacture-and-discard
  loop that died at ~100k iterations (id table full while value cells still
  pinned the ids) now runs until `sp_buf` fills. `gc_strpool` gate does ~800k
  string-id allocations (4× `MAX_STR`) and completes.
* New ceiling is **byte-bound**: `sp_buf` (8 MiB) is never reclaimed, so an
  unbounded manufacture-and-discard loop now dies at ~300–600k allocations
  (depending on string size) with a clean, catchable "string pool exhausted"
  rather than at the id table. Workloads whose *live* byte footprint stays
  bounded are effectively unbounded in allocation count.
* Accumulation (`s += "x" + i`) is **not** helped: the intermediates are
  mid-buffer byte holes, which only compaction can reclaim (below).

## Why a moving/compacting collector was NOT shipped

Compaction (slide live strings down in `sp_buf`, rewrite `st_off[id]`) would
reclaim bytes too, but it invalidates every raw `sp_buf` offset/pointer held
across the collection. These are pervasive and not cheaply enumerable:

1. **`str_new` copy-sources are raw `sp_buf` pointers.** Callers pass
   `v_string_bytes(&sp_buf[st_off[sid] + j], 1)` (regex VM, `charAt`, spread,
   `for..of` over a string — 6+ sites) — a `&sp_buf[…]` pointer straight into
   `str_new`. If `str_new` compacted at entry it would move the bytes `p` points
   at *before copying from `p`* → corruption.
2. **The build cursor `_bld_start`** is a raw `sp_top` offset held across an
   entire `bld_begin … bld_end` build, including builds that invoke user
   `toString`/getters (JSON.stringify, `obj + ""`) which allocate strings. A
   compaction mid-build relocates the in-progress bytes.
3. **`str_ptr()` results** are raw `&sp_buf[off]` pointers; several callers hold
   one across subsequent allocations (`module.ad`, `fetch.ad`, `url.ad`,
   `bigint.ad`, `collections.ad`).
4. **Regex/lex byte cursors** index `sp_buf` directly.

Proving no such pointer survives a compaction — or refactoring every site to be
compaction-safe — is a multi-file audit too risky for one behavior-preserving
pass. Under the "a live-free is worse than a leak" mandate, it is deferred.

## Compaction plan (when byte reclamation is needed)

The safe path is to make **`sp_buf` bytes never move under a raw pointer**, then
compact only at a quiescent point. Steps, smallest-first:

1. **Eliminate raw `sp_buf` copy-sources into `str_new`.** Add
   `str_new_from_pool(sid, off, len)` that copies *within* the pool by id+offset
   (recomputing `st_off[sid]` after any collection), and convert the
   `&sp_buf[st_off[sid]+j]` call sites (regex VM, `charAt`, string spread/iter)
   to it. This removes hazard (1) — the dominant one.
2. **Bracket every `bld_begin … bld_end` build with a `gc_no_compact` counter**
   (like `gc_disabled`), so compaction can never fire mid-build. Non-moving id
   reclamation still runs (it does not touch bytes); only the *byte-moving* phase
   is suppressed. This neutralizes hazard (2).
3. **Audit/convert `str_ptr()` holders** (hazard 3) to re-fetch `str_ptr(sid)`
   after any call that can allocate, or to bracket with `gc_no_compact`. There
   are ~8 sites; each is local.
4. **Add the compaction sweep** to run only when byte pressure is high
   (`sp_top` near `SP_CAP`) AND `gc_no_compact == 0` AND `gc_disabled == 0`:
   mark live ids (reuse Phase-4 marking), then in ONE ascending pass over live
   ids slide bytes down and rewrite `st_off[id]` (ids are stable handles, so no
   `v_ref`/`p_key`/AST rewrite is needed — only `st_off`). Set `sp_top` to the
   packed end. Because ids don't move, this is a "compacting collector with
   forwarding via the id table" — the cleanest moving-GC shape.
5. **Verify** with a `HAMNIX_JS_GC_STRESS`-driven `s += "x" + i` accumulation
   gate (unbounded intermediates → must now complete) plus the existing
   retained-strings gate re-run after every compaction (bytes intact).

Each step is independently landable and testable; step 1 alone (plus keeping
non-moving id reclamation) removes the single largest compaction hazard.
