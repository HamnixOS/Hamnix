/*
 * tests/u-binary/src/dlopen_demo/dlopen_demo.c -- U44 runtime dlopen()
 * fixture.
 *
 * dynamic_hello (U42) and dynamic_ns_hello (U43) prove LOAD-TIME
 * dynamic linking: the kernel loads ld.so, ld.so resolves the
 * binary's DT_NEEDED list (libc.so.6) at startup. This fixture goes
 * one step further -- RUNTIME dlopen():
 *
 *   1. main() runs (load-time linking already done).
 *   2. dlopen("libanswer.so", RTLD_NOW) asks the ALREADY-RUNNING
 *      ld.so to open + map + relocate a NEW shared object on demand.
 *   3. dlsym() looks up "answer" in the freshly-loaded DSO.
 *   4. The resolved function pointer is called.
 *
 * dlopen/dlsym are NOT a Hamnix kernel feature -- they are provided
 * by the stock glibc ld.so/libc we load. dlopen() is, mechanically,
 * the SAME work as a DT_NEEDED resolution (open the .so through the
 * process namespace, mmap its PT_LOADs with the reserve+overlay
 * idiom, apply RELA relocations, run DT_INIT) -- just triggered by a
 * libc call instead of by ld.so's startup pass. So a passing run
 * here proves the §4 loader's namespace-routed open() + honest mmap
 * are sufficient for the full dlopen() path, with zero extra kernel
 * code: libdl is just a thin shim over _dl_open inside libc.
 *
 * libanswer.so is a purpose-built one-function DSO (libanswer.c) --
 * deliberately NOT a glibc library, so the test sidesteps glibc's
 * symbol-versioning / merged-libm / IFUNC machinery and isolates the
 * loader's dlopen() path as the single thing under test.
 *
 * Marker on serial:  "U44 dlopen answer()=42"  == PASS.
 */
#include <stdio.h>
#include <dlfcn.h>

int main(void) {
    /* Plain basename: ld.so walks its default search path (the
     * directories the test stages libanswer.so into) -- no
     * LD_LIBRARY_PATH plumbing needed. */
    void *h = dlopen("libanswer.so", RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        printf("U44 dlopen FAILED: %s\n", dlerror());
        return 1;
    }
    int (*answer_fn)(void) = (int (*)(void)) dlsym(h, "answer");
    if (!answer_fn) {
        printf("U44 dlsym FAILED: %s\n", dlerror());
        return 1;
    }
    printf("U44 dlopen answer()=%d\n", answer_fn());
    dlclose(h);
    return 0;
}
