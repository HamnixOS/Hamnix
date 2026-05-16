# L-track HOWTO

The L-track is Hamnix's "load a stock Linux 6.12 .ko unchanged"
regression. This guide walks through running it end-to-end and
explains the common failure modes.

## Pipeline overview

    +-----------------+    make linux_tree     +-------------------+
    | nothing staged  | ---------------------> | linux-6.12.48/    |
    +-----------------+   (one-time, ~20 min)  | vmlinux + headers |
                                               +---------+---------+
                                                         |
                                       make modules install
                                                         v
                  scripts/build_linux_modules.sh    +----+----+
                  ----------------------------->   | *.ko    |
                                                   | staged  |
                                                   +----+----+
                                                        |
                                                        v
                                          scripts/test_l_track.sh
                                          (boots Hamnix in QEMU,
                                           insmod's each .ko,
                                           greps for marker line)

## To run L-track validation

### 1. Get a Linux 6.12 build tree

The fixtures are out-of-tree kernel modules — kbuild needs a
configured + built kernel source tree (Module.symvers, headers,
scripts/). One-time, on a developer machine:

    make -C tests/linux-modules linux_tree

This clones v6.12.48 (shallow), runs `defconfig` plus
`DEBUG_INFO_BTF=y`, and does a full kernel build. Expect ~20 minutes
and ~15 GB of disk.

If you already have a Linux 6.12.48 tree elsewhere, point at it:

    make -C tests/linux-modules modules install LINUX_TREE=/path/to/tree

### 2. Build the fixtures

    bash scripts/build_linux_modules.sh

The wrapper:

  * sentinels on `tests/linux-modules/linux-6.12.48/vmlinux` and
    prints a clear error if step 1 hasn't run
  * runs `make modules install` to build every `src/<name>/<name>.ko`
    and stage it as `tests/linux-modules/<name>.ko`
  * reports a per-fixture OK / MISSING table

### 3. Pre-flight check

    bash scripts/l_track_status.sh

Lists every fixture in `src/`, whether its `.ko` is staged, and
whether the kernel symbols it references are present in
`linux_abi/exports.ad`. A `READY` status means the fixture is
expected to PASS under `test_l_track.sh`. Anything else (NEEDS-BUILD,
NEEDS-EXPORTS, PLACEHOLDER) explains what's missing.

### 4. Run the regression

    bash scripts/test_l_track.sh

This rebuilds the Hamnix kernel, embeds the staged `.ko` files into
the cpio initramfs as `/lib/modules/6.12/<name>.ko`, boots in QEMU,
drives `insmod` + `rmmod` against each one, and greps the serial log
for the per-fixture marker (see `tests/linux-modules/EXPECTED.md`).

## Common failure modes

### Unresolved external symbol 'X'

The L1 loader in `linux_abi/loader.ad` couldn't find `X` in the
exports table. Either:

  * The fixture uses a Linux symbol Hamnix hasn't shimmed yet. Add
    an `_add_export("X", &_linux_X_shim)` row in the appropriate
    `linux_abi/api_<group>.ad` (or in `exports.ad` for the small
    set there), and a `_linux_X_shim` function that adapts Linux's
    calling convention to Hamnix's.
  * The fixture references an inline / static helper from a header
    that didn't actually get inlined. Build with `-fno-inline` and
    re-check the UND list with `nm -u tests/linux-modules/<name>.ko`.

### Missing struct offset

A relocation patched a field load (e.g. `dev->priv` in netdev),
and the offset Hamnix's shim used doesn't match Linux's struct
layout. `linux_abi/structs/` holds the BTF-derived offset tables;
regenerate from the pinned Linux tree:

    python3 scripts/gen_linux_abi.py tests/linux-modules/linux-6.12.48

If `gen_linux_abi.py` doesn't already cover the struct, add it to
the dumper's list there and re-run.

### Wrong relocation type

Symptom: module loads but jumps to garbage / triple-faults. The
loader logs the unhandled relocation as `R_X86_64_<NN>` in the
serial output. Most fixtures need only `R_X86_64_PC32` (PC-relative
calls), `R_X86_64_PLT32` (calls via the PLT, treated identically to
PC32 since we have no lazy binding), and `R_X86_64_64` (absolute
data references). If a new relocation type shows up, extend
`linux_abi/loader.ad`'s `apply_relocations` switch.

### Marker not found in serial log

The `.ko` loaded but `printk` didn't reach the captured serial
output. Almost always one of:

  * The fixture's printk uses `%d` / `%s` / etc. but `_linux_printk_shim`
    drops variadic args. Extend the shim to detect `%` in the format
    and fan out to `printk1` / `printk2`.
  * The fixture's `module_init` returned non-zero — the kernel logs
    "module init failed: -N". Check the error path inside the
    fixture .c.
  * The module loaded into an unmapped page. The L1 loader's
    `module_alloc` path needs the module heap region present in the
    page tables — see `mm/module_heap.ad`.

## How to add a new fixture

Mirroring `tests/linux-modules/README.md`'s steps but with the
validation pieces highlighted:

1. **Source**: create `tests/linux-modules/src/<name>/<name>.c` as
   a normal Linux module. The `module_init` printk MUST start with
   `L<N>: <name>.ko module_init` (or a per-API success line; see
   the table in `tests/linux-modules/EXPECTED.md`).

2. **Makefile**: copy `src/hello/Makefile` to `src/<name>/Makefile`
   and rename `hello` → `<name>`.

3. **Build**: `bash scripts/build_linux_modules.sh` will pick up the
   new fixture from the glob and produce `tests/linux-modules/<name>.ko`.

4. **Exports**: `bash scripts/l_track_status.sh` will flag any Linux
   symbols the new fixture pulls in that aren't in `exports.ad` yet.
   Add the shims (see "Unresolved external symbol" above).

5. **Contract**: add a row for `<name>` to
   `tests/linux-modules/EXPECTED.md` with the exact marker string.

6. **Regression**: add `[<name>]="<marker>"` to the `MARKERS`
   associative array in `scripts/test_l_track.sh`.

7. **Commit**: `git add src/<name>/ <name>.ko EXPECTED.md` plus any
   `linux_abi/` changes.

## Related files

  * `tests/linux-modules/README.md`     — fixture layout / build flow
  * `tests/linux-modules/EXPECTED.md`   — marker-string contract
  * `linux_abi/TARGET_ABI.md`           — pinned Linux version + refresh policy
  * `linux_abi/exports.ad`              — kernel symbol table
  * `linux_abi/loader.ad`               — ELF + relocation handling
  * `scripts/build_linux_modules.sh`    — fixture build wrapper
  * `scripts/l_track_status.sh`         — readiness report
  * `scripts/test_l_track.sh`           — end-to-end regression
