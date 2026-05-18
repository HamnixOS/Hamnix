# u_cpython build notes

U41 ships `tests/u-binary/u_cpython` -- a fully-static CPython 3.11.x
interpreter that runs on Hamnix's U-track Linux ABI. This file
explains how the binary is built so the next agent can rebuild,
upgrade to a newer 3.x, or swap in a musl-linked variant.

## Why CPython (and not just MicroPython)?

U39 shipped MicroPython 1.22.0 (~900 KB) as the proof-of-concept
that Hamnix's Linux ABI is wide enough to host a real Python
interpreter. MicroPython, however, is NOT what `apt install python3`
delivers -- it implements a strict subset of Python 3, ships almost
none of the stdlib, and exercises a narrower syscall surface.

U41 raises the bar to **CPython** -- the same upstream interpreter
Debian packages and the same binary that runs every pip-installed
package, every Django site, every `python3 manage.py runserver` you
ever cared about. The fully-static build:

- Embeds the full standard library (`os`, `sys`, `io`, `re`, `json`,
  `collections`, `argparse`, `pathlib`, `unittest`, ...).
- Statically links libc, libm, libpthread, libdl, libutil into one
  ELF -- no dynamic linker required, no shared objects to ship.
- Lands at ~5.7 MB stripped (vs ~25 MB unstripped, vs ~900 KB
  MicroPython).
- Exercises a much wider syscall surface than MicroPython:
  `getrandom`, `clock_nanosleep`, `prlimit64`, `fstatat`,
  `readlinkat`, `mprotect`, plus the same brk/mmap/futex set as
  MicroPython. This is the surface `apt-installable Python apps`
  routinely walk.

## What's actually in `u_cpython`?

The committed binary is CPython 3.11.10's `python` interpreter,
linked `-static` (NOT `-static-pie` -- see below). Built from
upstream python.org tarball with:

```
CFLAGS="-fPIC" ./configure \
    --disable-shared \
    --without-pymalloc-debug \
    --without-doc-strings \
    --disable-test-modules \
    LDFLAGS="-static"
make -j$(nproc)
strip --strip-all python
```

The interpreter implements full Python 3.11 semantics. The `-c
"print('hello from CPython on Hamnix')"` invocation in the U41 test
exercises:

- ELF static load + page-in (U5, U10, U14).
- glibc-static crt1 startup (U18, U19).
- `set_tid_address`, `arch_prctl(ARCH_SET_FS)`, `set_robust_list`,
  `rseq`, `prlimit64` -- the standard glibc-static init prelude.
- `brk(NULL)` / `brk(end)` for the Python heap (now per-task brk
  thanks to M16.104 -- the MicroPython-era workaround of
  `-X heapsize=64k` is unnecessary here).
- `mmap(anon, RW)` for stdlib import + bytecode + object arenas.
- `getrandom(buf, 16, 0)` for `hash randomization` + `os.urandom`
  seeding.
- `openat(AT_FDCWD, "/proc/self/exe", O_RDONLY)` and
  `readlinkat(AT_FDCWD, "/proc/self/exe", ...)` for sys.executable.
- `clock_gettime(CLOCK_MONOTONIC, ...)` for the interpreter's
  startup timer.
- `write(1, "hello from CPython on Hamnix\n", 29)` -- the actual
  success marker.
- `exit_group(0)` -- normal interpreter teardown.

CPython does NOT use io_uring on the boot path. epoll-based async
runs through `_asyncio` which is lazy-loaded; the boot path of
`-c "print(...)"` doesn't touch it. So the `-ENOSYS` triage for
U41 should be MUCH shorter than the MicroPython HOWTO predicted.

## Why `-static`, not `-static-pie`?

Debian trixie's stock libpython3.13.a is built without -fPIC, which
breaks `gcc -static-pie -lpython3.13`. We sidestep that by building
CPython entirely from upstream source, with our own CFLAGS=-fPIC --
but a few internal CPython objects (e.g. `_freeze_module`,
`Modules/_freeze_module.o`, and Modules/_decimal/libmpdec/*) still
end up with R_X86_64_32 relocations that `-static-pie` rejects.
Plain `-static` accepts them.

Hamnix's ELF loader handles BOTH plain `-static` (ET_EXEC) and
static-pie (ET_DYN, INTERP=NULL). U19 lit the static-pie path; the
ET_EXEC path lit at U5 long before that. So `-static` is the
operationally simpler choice here.

If a future agent needs static-pie (for ASLR inside Hamnix, or to
match the U39 MicroPython binary's flags), rebuild with:

```
CFLAGS="-fPIC -fPIE" LDFLAGS="-static-pie -fPIE" ./configure ...
```

Expect link failures on the internal `Modules/_freeze_module.o` /
libmpdec objects; either rebuild those objects with `-fPIC` manually,
or apply the upstream patch
[gh-101282](https://github.com/python/cpython/issues/101282) which
adds `-fPIC` to those translation units.

## How to rebuild

```
make -C tests/u-binary/src/cpython clean
make -C tests/u-binary/src/cpython install
```

This will:
1. Download `Python-3.11.10.tar.xz` from python.org (~20 MB).
2. Extract into `build/Python-3.11.10/`.
3. Run `./configure` with the static-flavour flags above.
4. `make -j$(nproc)` -- the slow step. 15-30 min on a modern x86_64
   host; the link is serial so multi-core only helps the compile
   phase.
5. Strip + OSABI-stamp + copy to `tests/u-binary/u_cpython`.

Total disk: ~500 MB in `build/` (source + objects); after a
successful `install` you can `make clean` to reclaim it.

Total wall time: ~15-30 min on a recent (8+ core) x86_64 host.

## Host requirements

- `gcc` (any 9+).
- `make`.
- `libc6-dev` providing `/usr/lib/x86_64-linux-gnu/libc.a` (the
  static-glibc archive). Debian: `apt-get install libc6-dev`.
- `wget` OR `curl` (to fetch the tarball).
- `tar`, `xz-utils`.

The Makefile auto-detects these. If any is missing, it prints a
clear `SKIP` line and exits 0 -- mirrors the U22/U24/U39/U40
pattern so CI in minimal environments keeps moving.

## Troubleshooting

### `-fPIC` error during link

If you see something like

```
relocation R_X86_64_32 against symbol `XYZ' can not be used when
making a PIE object
```

you tried to build with `-static-pie` against an object that wasn't
compiled `-fPIC`. Drop back to plain `-static` (the default in this
Makefile) or audit which `.o` is causing it.

### `ld: cannot find -lcrypt` / `-ldl`

Older Debian releases ship libdl + libcrypt as separate static
archives. Trixie merges them into libc. If you see the error,
either: install `libcrypt-dev` and `libdl-dev`, or pass
`--without-decimal-contextvar` to drop the dependency.

### Build is too slow / fails: ship Makefile only

If the host can't build CPython in a reasonable time, the
Makefile + HOWTO are still valuable -- a future agent on a
properly-configured host can `make install` to produce the
staged binary without touching anything else. The U41 test
script SKIPs cleanly if `tests/u-binary/u_cpython` is missing,
the same way U22/U24/U39/U40 do.

## Syscall surface CPython actually hit

Run the U41 test:

```
bash scripts/test_u41_cpython.sh
```

Grep the captured log for `linux_u: ENOSYS nr=N` lines. Each
distinct N is a syscall CPython invoked that Hamnix's U-track
hasn't bound to a real body yet. Cross-reference against
the Linux syscall table (`arch/x86/entry/syscalls/syscall_64.tbl`
in upstream Linux source). Most of CPython's `-ENOSYS` hits on
the `-c "print(...)"` boot path are tolerable:

- `epoll_create1` (291), `epoll_ctl` (233), `epoll_wait` (232) --
  CPython falls back to `select(2)`.
- `set_robust_list` (273) -- glibc-static prologue, no-op safe.
- `rseq` (334) -- restartable sequences, no-op safe.
- `prlimit64` (302) -- already handled at U18.

The U41 test does NOT fix any missing syscalls; that's deferred
to a follow-up agent batching the cd-validation agent's syscall.ad
work. See TODO.md.

## How to upgrade to CPython 3.12 / 3.13

Bump `PY_VERSION` in the Makefile. CPython's `--disable-shared`
+ `LDFLAGS=-static` story is stable across the 3.x line. Note:
3.12 introduced `_PyRuntime`-driven init that touches more of the
syscall surface during startup; expect a couple new `-ENOSYS` hits
when you bump.

## stdlib embedding (this commit)

CPython's interpreter init unconditionally imports the `encodings`
package + `encodings.utf_8` (plus `codecs`, `io`, `abc`,
`_collections_abc`, `_weakrefset`, `types`, `os`, `posixpath`,
`genericpath`, `enum`, `stat`, `_sitebuiltins`, `site`) before it
hits the eval loop. None of those modules ship inside the static
binary — they're plain `.py` files under the upstream source's
`Lib/` directory. Without them, CPython aborts during
`init_fs_encoding`:

```
Fatal Python error: init_fs_encoding: failed to get the Python codec
of the filesystem encoding
ModuleNotFoundError: No module named 'encodings'
```

This commit embeds the upstream `Lib/` tree into the Hamnix
initramfs at `/usr/lib/python3.11/` via a new build-time hook in
`scripts/build_initramfs.py`:

```
HAMNIX_EMBED_PYLIB=$(make --no-print-directory \
    -C tests/u-binary/src/cpython stdlib-path) \
    INIT_ELF=build/user/hamsh.elf \
    HAMNIX_EMBED_UBIN=1 \
    python3 scripts/build_initramfs.py
```

The `stdlib-path` Make target prints
`tests/u-binary/src/cpython/build/Python-3.11.10/Lib` — the path
into which the Makefile's `tar xf` step lands the upstream source.

`build_initramfs.py` walks that directory, mirrors every `.py` file
to `/usr/lib/python3.11/<relpath>` in the cpio archive, and SKIPs:
- `__pycache__/` — platform-specific bytecode caches, ~2 MiB of
  bulk that CPython rebuilds from .py source at import time anyway.
- `lib-dynload/` — compiled C extensions (.so) that need a dynamic
  loader. Hamnix has none on the U-track.

Final wire-up: the test script sets `PYTHONHOME=/usr/lib/python3.11`
(and `PYTHONPATH` as a belt+braces fallback) via hamsh's
`var_table`. `user/hamsh.ad::_build_envp_block` exports every shell
variable to the spawned child's envp, so CPython sees them.

### Size cost

- 1828 .py files, ~32 MiB of source.
- cpio overhead: ~140 bytes per entry → ~256 KiB extra.
- The generated `fs/initramfs_blob.S` (the .byte-encoded assembly
  the kernel `.incbin`-includes) grows ~6x larger than the binary
  archive due to ASCII expansion. With the stdlib embedded the
  blob is ~190 MiB — well over GitHub's 100 MiB push cap, which
  is why HAMNIX_EMBED_PYLIB defaults OFF. The default committed
  initramfs stays small; only the U41 test sets the env var, and
  the test's EXIT trap restores the default blob.

## Known blocker after stdlib embed: in-kernel cpio cap

After this commit, the U41 test may or may not PASS depending on
whether `fs/cpio.ad`'s `NR_FILES=192` cap accommodates the full
stdlib. The baseline initramfs already has ~150 entries (build/user
ELFs, etc/, build/mod/, tests/linux-modules/*.ko, busybox applets),
and the stdlib brings in ~1800 more `.py` files. The kernel's
`cpio_init()` logs:

```
cpio: file table full at 192 entries
```

and the tail of the archive (whichever .py files land after entry
192) is silently dropped. CPython then sees a partial stdlib — most
notably `encodings/__init__.py` may be missing — and re-aborts at
`init_fs_encoding`.

The fix is a one-line bump of `NR_FILES` in `fs/cpio.ad` (e.g.,
to 4096). It's deferred to a follow-up commit because `fs/` is
owned by other agents this round (the cpio module sits next to the
AHCI/NVMe write-path and partition-parser work). The Makefile +
HOWTO + the build-side embedding hook are still valuable: once the
cap bumps, this same `test_u41_cpython.sh` flips to PASS without
further changes.

Follow-up options if the cpio cap turns out to also be too small
(unlikely — 4096 is plenty), or to fundamentally avoid the in-
memory file_table:
1. **Frozen modules.** Rebuild CPython with `Tools/scripts/
   freeze_modules.py` so `encodings`, `importlib`, `codecs`, etc.
   are compiled into the binary's static data. Eliminates the
   /usr/lib/python3.11/ tree entirely. ~25 min rebuild + larger
   binary (~7-8 MiB stripped instead of 5.7).
2. **Lazy file_table.** Replace the fixed-size array in
   `fs/cpio.ad` with a hash-keyed lazy lookup over the raw cpio
   blob. Walks once per open(); takes the cap pressure off the
   build side.

Diagnostic next step for the follow-up agent:

```
# Bump NR_FILES in fs/cpio.ad to 4096, recompile, rerun
# bash scripts/test_u41_cpython.sh.
```

## Files

- `Makefile` -- this build.
- `HOWTO.md` -- this file.
- `build/` -- gitignored; holds the source tarball + build tree.
- `../../u_cpython` -- gitignored; the staged binary (host-built).
