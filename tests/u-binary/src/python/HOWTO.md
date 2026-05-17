# u_python build notes

U39 ships `tests/u-binary/u_python` -- a static-PIE Python
interpreter that runs on Hamnix's U-track Linux ABI. This file
explains how the binary was built so the next agent can rebuild,
upgrade, or swap to a different Python implementation.

## What's actually in `u_python`?

The committed binary is MicroPython 1.22.0's `unix` port, variant
`minimal`, linked `-static-pie`. ~900 KB stripped. The interpreter
implements enough of Python 3 to run

```python
print('hello from hamnix')
print(1 + 2 * 3)
for x in range(3): print(x)
```

and the rest of the basic language (arithmetic, lists, dicts,
control flow, functions, classes, exceptions). Standard-library
coverage is intentionally tiny -- this is the Python that fits
inside an MCU port. It is NOT pip-installable Python; this is a
proof-of-concept that the Hamnix Linux ABI is wide enough to host
a real interpreter.

## Why not CPython?

The host's `libpython3.13.a` is built without `-fPIC` on Debian
trixie, so `gcc -static-pie ... -l:libpython3.13.a` fails with

```
relocation R_X86_64_32 against symbol `_PyRuntime' can not be
used when making a PIE object
```

Building CPython from source with `--without-shared --enable-pie`
works but takes 20-40 min and produces a ~25-30 MB binary
(close to GitHub's 100 MB push limit even after stripping; the
default initramfs build already gates u_* binaries behind
`HAMNIX_EMBED_UBIN=1` for exactly this reason).

MicroPython is the right Python to land FIRST because:

1. It's ~30x smaller (~900 KB vs ~25 MB).
2. The build is 60s, not 30 min.
3. It exercises the same Linux syscall surface for the "boot,
   print, exit" path. brk + mmap + futex + clock_gettime +
   getrandom + read + write -- exactly the U18..U27 surface.
4. The contract `u_python -c "print(...)"` is identical, so the
   next agent can swap to CPython without changing the test
   fixture.

## How to rebuild

```
make -C tests/u-binary/src/python clean
make -C tests/u-binary/src/python install
```

This will:
1. Clone MicroPython v1.22.0 into `build/micropython/`
2. Build mpy-cross (the bytecode compiler -- needed by the
   unix port at build time, not at runtime)
3. Init MicroPython's git submodules (mbedtls + micropython-lib +
   berkeley-db; only the third is consumed by the `minimal`
   variant)
4. Build the `minimal` variant with `-static-pie`
5. Copy + OSABI-stamp the result to `tests/u-binary/u_python`

Total runtime: ~60-90s on a modern x86_64 host.

## How to upgrade to full CPython

When the next agent wants a real CPython:

1. `wget https://www.python.org/ftp/python/3.11.10/Python-3.11.10.tar.xz`
2. `tar xf Python-3.11.10.tar.xz && cd Python-3.11.10`
3. `CFLAGS="-fPIC" ./configure --disable-shared --enable-optimizations=no --without-pymalloc-debug --disable-test-modules`
4. `make -j$(nproc) python`
5. Re-link as static-pie: `gcc -static-pie -o u_python Programs/python.o libpython3.11.a -lm -lpthread -ldl`

Expect 50-100 new `-ENOSYS` hits the first time CPython boots
under Hamnix. The U-track agent that does this swap should:

  - Run `strace -f -e trace=!nanosleep python3.11 -c "print('hi')" 2>&1 | sort -u > /tmp/cpython_syscalls.txt`
    on the host to enumerate the full syscall surface.
  - Cross-reference each missing syscall against
    `linux_abi/u_syscalls.ad`. Most missing ones are easy
    (epoll_create1 returns -ENOSYS; CPython falls back to select);
    a few need real work (the io_uring path is well off the
    happy path and can stay stubbed).

## Syscall surface MicroPython actually uses

From a `strace -e trace=process,memory,desc,file,signal` of
`micropython -c "print('hi')"` on the host:

```
brk(NULL) / brk(end)            -- already handled (U18)
mmap(anon, RW)                  -- already handled (U7)
write(1, ...)                   -- already handled (U4)
exit_group(0)                   -- already handled (U4)
arch_prctl(ARCH_SET_FS, ...)    -- already handled (U4)
set_tid_address                 -- already handled (U4)
readlink("/proc/self/exe", ...) -- already handled (U21)
prlimit64(0, RLIMIT_STACK)      -- already handled (U18)
getrandom(buf, 16, 0)           -- already handled (U18)
rseq                            -- already handled (U18)
mprotect                        -- already handled (U18, no-op)
rt_sigaction                    -- already handled (U18, no-op)
rt_sigprocmask                  -- already handled (U18, no-op)
```

So MicroPython exercises the syscall surface already paved by
U18..U27. NO new kernel work is required to print "hello from
hamnix" -- this commit just adds the fixture + test script and
proves the existing surface scales to a real interpreter.

If `make install` is run on a host without git or `-static-pie`
the build no-ops with a SKIP message and the committed
`tests/u-binary/u_python` is used as-is.
