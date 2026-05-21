/*
 * tests/u-binary/src/dlopen_demo/libanswer.c -- U44 dlopen() target DSO.
 *
 * A trivial purpose-built shared object so the runtime-dlopen() test
 * does not depend on glibc's symbol-versioning / merged-libm /
 * IFUNC quirks. dlopen_demo.c dlopen()s this, dlsym()s "answer", and
 * calls it -- the cleanest possible proof that ld.so can map + relocate
 * + symbol-resolve a fresh DSO on demand at runtime.
 */
int answer(void) {
    return 42;
}
