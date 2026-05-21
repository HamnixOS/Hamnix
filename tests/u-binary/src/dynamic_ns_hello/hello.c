/*
 * tests/u-binary/src/dynamic_ns_hello/hello.c -- U43 capstone fixture.
 *
 * Identical in shape to dynamic_hello (a stock, dynamically-linked
 * glibc binary with PT_INTERP=/lib64/ld-linux-x86-64.so.2 and
 * DT_NEEDED=[libc.so.6]) -- only the marker string differs.
 *
 * dynamic_hello (U42) proves Hamnix can load a dynamic ELF when its
 * interpreter and libc sit at their canonical paths in the FLAT
 * initramfs. U43 proves the loader is NAMESPACE-CORRECT: this binary
 * is run via /bin/distrorun, which privatises the namespace and binds
 * /lib64 + /lib onto a per-distro backing tree. The kernel ELF
 * loader's PT_INTERP lookup (fs/elf.ad::_load_interp_elf ->
 * ns_blob_ptr -> resolve_path) and ld.so's DT_NEEDED open() of
 * libc.so.6 both resolve through that namespace bind -- not a
 * hardcoded global path.
 *
 * Marker on serial:  "U43 dynamic-ns hello"  == PASS.
 */
#include <stdio.h>

int main(void) {
    puts("U43 dynamic-ns hello");
    return 0;
}
