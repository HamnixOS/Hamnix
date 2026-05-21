/*
 * tests/u-binary/src/proc_translation/proc_translation.S
 *
 * M16.134 — Layer-2 /proc/<name> -> /dev/<name> translation regression.
 *
 * Pure x86_64 asm, no libc. Built into a host-side Linux ELF with
 * OSABI=ELFOSABI_LINUX so Hamnix's U2 detector flips
 * is_linux_userspace=1 on exec and routes syscalls through
 * linux_u_syscall_dispatch in linux_abi/u_syscalls.ad. That's the only
 * code path that runs the new _u_translate_proc_to_dev helper.
 *
 * What this binary tests:
 *
 *   1. open("/proc/cpuinfo", O_RDONLY) succeeds and read() returns > 0.
 *      Without the Layer-2 translation the native rootfs has no
 *      /proc/cpuinfo (only /dev/cpuinfo) and we'd get -ENOENT.
 *      Marker: "[proc-translation] /proc/cpuinfo open OK\n"
 *
 *   2. open("/dev/cpuinfo", O_RDONLY) succeeds and read() returns > 0.
 *      Sanity reference — the same cdev via its native path.
 *      Marker: "[proc-translation] /dev/cpuinfo open OK\n"
 *
 *   3. The two reads produce byte-identical content (devcpuinfo_read
 *      is deterministic within a boot — CPUID leaves + cpus_online).
 *      Marker: "[proc-translation] /proc/cpuinfo == /dev/cpuinfo OK\n"
 *
 *   4. The captured blob contains "vendor:" (devcpuinfo_read emits a
 *      "vendor: <id>" line first), confirming it's the real cdev
 *      output and not, e.g., a stale procfs renderer leak.
 *      Marker: "[proc-translation] vendor line present OK\n"
 *
 *   5. exit_group(0).
 *
 * On any failure we write a "[proc-translation] <name> FAIL\n" line
 * and exit with a distinct non-zero status so the harness can pinpoint
 * the failing step.
 */

    .section .text
    .globl _start
_start:
    /* ---- 1. open("/proc/cpuinfo", O_RDONLY) ---------------------- */
    movq    $2, %rax                   /* SYS_open                    */
    leaq    proc_path(%rip), %rdi
    xorq    %rsi, %rsi                 /* O_RDONLY = 0                */
    xorq    %rdx, %rdx
    syscall
    testq   %rax, %rax
    js      fail_open_proc
    movq    %rax, %r12                 /* save fd for read + close    */

    movq    $1, %rax                   /* SYS_write                   */
    movq    $1, %rdi
    leaq    msg_open_proc_ok(%rip), %rsi
    movq    $len_open_proc_ok, %rdx
    syscall

    /* ---- 1b. read(fd, proc_buf, 384) ----------------------------- */
    movq    $0, %rax                   /* SYS_read                    */
    movq    %r12, %rdi
    leaq    proc_buf(%rip), %rsi
    movq    $384, %rdx
    syscall
    testq   %rax, %rax
    jle     fail_read_proc
    movq    %rax, %r13                 /* save proc_n                 */

    /* close(fd) */
    movq    $3, %rax                   /* SYS_close                   */
    movq    %r12, %rdi
    syscall

    /* ---- 2. open("/dev/cpuinfo", O_RDONLY) ----------------------- */
    movq    $2, %rax                   /* SYS_open                    */
    leaq    dev_path(%rip), %rdi
    xorq    %rsi, %rsi
    xorq    %rdx, %rdx
    syscall
    testq   %rax, %rax
    js      fail_open_dev
    movq    %rax, %r12

    movq    $1, %rax                   /* SYS_write                   */
    movq    $1, %rdi
    leaq    msg_open_dev_ok(%rip), %rsi
    movq    $len_open_dev_ok, %rdx
    syscall

    /* ---- 2b. read(fd, dev_buf, 384) ------------------------------ */
    movq    $0, %rax                   /* SYS_read                    */
    movq    %r12, %rdi
    leaq    dev_buf(%rip), %rsi
    movq    $384, %rdx
    syscall
    testq   %rax, %rax
    jle     fail_read_dev
    movq    %rax, %r14                 /* save dev_n                  */

    /* close(fd) */
    movq    $3, %rax
    movq    %r12, %rdi
    syscall

    /* ---- 3. byte-equality compare -------------------------------- *
     * Both reads come from the same devcpuinfo_read; if /proc/cpuinfo
     * routed anywhere else (a stale procfs renderer, an ENOENT path)
     * the bytes won't match. Compare lengths first, then memcmp the
     * payload. */
    cmpq    %r13, %r14
    jne     fail_compare_len
    /* memcmp(proc_buf, dev_buf, r13) */
    xorq    %rcx, %rcx                 /* i = 0                       */
cmp_loop:
    cmpq    %r13, %rcx
    jae     cmp_done
    leaq    proc_buf(%rip), %rsi
    movzbl  (%rsi, %rcx), %eax
    leaq    dev_buf(%rip), %rsi
    movzbl  (%rsi, %rcx), %edx
    cmpb    %dl, %al
    jne     fail_compare_byte
    incq    %rcx
    jmp     cmp_loop
cmp_done:
    /* equality confirmed — emit the canonical PASS marker. */
    movq    $1, %rax
    movq    $1, %rdi
    leaq    msg_eq_ok(%rip), %rsi
    movq    $len_eq_ok, %rdx
    syscall

    /* ---- 4. scan proc_buf for "vendor:" -------------------------- *
     * devcpuinfo_read's first line is "vendor: <id>\n". A successful
     * translation means that string lives at offset 0..7 of proc_buf.
     * Scan rather than hard-pin offset so a future leading-whitespace
     * tweak doesn't break this assert.
     *
     * Needle is 7 bytes: 'v','e','n','d','o','r',':'.
     */
    xorq    %rcx, %rcx                 /* i = 0                       */
    movq    %r13, %r8                  /* limit = proc_n              */
    subq    $7, %r8
    jbe     fail_no_vendor
scan_loop:
    cmpq    %r8, %rcx
    ja      fail_no_vendor
    leaq    proc_buf(%rip), %rsi
    /* compare 7 bytes starting at proc_buf[rcx] against "vendor:" */
    movzbl  (%rsi, %rcx), %eax
    cmpb    $'v', %al
    jne     scan_next
    movzbl  1(%rsi, %rcx), %eax
    cmpb    $'e', %al
    jne     scan_next
    movzbl  2(%rsi, %rcx), %eax
    cmpb    $'n', %al
    jne     scan_next
    movzbl  3(%rsi, %rcx), %eax
    cmpb    $'d', %al
    jne     scan_next
    movzbl  4(%rsi, %rcx), %eax
    cmpb    $'o', %al
    jne     scan_next
    movzbl  5(%rsi, %rcx), %eax
    cmpb    $'r', %al
    jne     scan_next
    movzbl  6(%rsi, %rcx), %eax
    cmpb    $':', %al
    jne     scan_next
    /* match */
    jmp     scan_hit
scan_next:
    incq    %rcx
    jmp     scan_loop
scan_hit:
    movq    $1, %rax
    movq    $1, %rdi
    leaq    msg_vendor_ok(%rip), %rsi
    movq    $len_vendor_ok, %rdx
    syscall

    /* ---- 5. open("/proc/self/stat", O_RDONLY) -------------------- *
     * §13: /proc/self resolution. The Layer-2 shim rewrites
     * "/proc/self/<leaf>" to "/proc/<pid>/<leaf>" where <pid> is the
     * caller's own pid, then vfs_open routes it through devproc.
     * Without the resolver this would -ENOENT (the native namespace
     * has no "self" entry). A successful open + non-empty read whose
     * first byte is an ASCII digit (field 1 of /proc/<pid>/stat is
     * the pid) proves the whole path works. */
    movq    $2, %rax                   /* SYS_open                    */
    leaq    self_path(%rip), %rdi
    xorq    %rsi, %rsi
    xorq    %rdx, %rdx
    syscall
    testq   %rax, %rax
    js      fail_open_self
    movq    %rax, %r12

    movq    $0, %rax                   /* SYS_read                    */
    movq    %r12, %rdi
    leaq    self_buf(%rip), %rsi
    movq    $256, %rdx
    syscall
    testq   %rax, %rax
    jle     fail_read_self

    movq    $3, %rax                   /* SYS_close                   */
    movq    %r12, %rdi
    syscall

    /* first byte of /proc/<pid>/stat must be an ASCII digit */
    leaq    self_buf(%rip), %rsi
    movzbl  (%rsi), %eax
    cmpb    $'0', %al
    jb      fail_self_shape
    cmpb    $'9', %al
    ja      fail_self_shape

    movq    $1, %rax
    movq    $1, %rdi
    leaq    msg_self_ok(%rip), %rsi
    movq    $len_self_ok, %rdx
    syscall

    /* ---- 6. exit_group(0) ---------------------------------------- */
    movq    $231, %rax
    xorq    %rdi, %rdi
    syscall
spin0:
    jmp     spin0

fail_open_self:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_open_self(%rip), %rsi
    movq    $len_fail_open_self, %rdx
    syscall
    movq    $231, %rax
    movq    $8, %rdi
    syscall
spin8:
    jmp     spin8

fail_read_self:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_read_self(%rip), %rsi
    movq    $len_fail_read_self, %rdx
    syscall
    movq    $231, %rax
    movq    $9, %rdi
    syscall
spin9:
    jmp     spin9

fail_self_shape:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_self_shape(%rip), %rsi
    movq    $len_fail_self_shape, %rdx
    syscall
    movq    $231, %rax
    movq    $10, %rdi
    syscall
spin10:
    jmp     spin10

fail_open_proc:
    movq    $1, %rax
    movq    $2, %rdi                   /* stderr                      */
    leaq    msg_fail_open_proc(%rip), %rsi
    movq    $len_fail_open_proc, %rdx
    syscall
    movq    $231, %rax
    movq    $1, %rdi
    syscall
spin1:
    jmp     spin1

fail_read_proc:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_read_proc(%rip), %rsi
    movq    $len_fail_read_proc, %rdx
    syscall
    movq    $231, %rax
    movq    $2, %rdi
    syscall
spin2:
    jmp     spin2

fail_open_dev:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_open_dev(%rip), %rsi
    movq    $len_fail_open_dev, %rdx
    syscall
    movq    $231, %rax
    movq    $3, %rdi
    syscall
spin3:
    jmp     spin3

fail_read_dev:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_read_dev(%rip), %rsi
    movq    $len_fail_read_dev, %rdx
    syscall
    movq    $231, %rax
    movq    $4, %rdi
    syscall
spin4:
    jmp     spin4

fail_compare_len:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_compare_len(%rip), %rsi
    movq    $len_fail_compare_len, %rdx
    syscall
    movq    $231, %rax
    movq    $5, %rdi
    syscall
spin5:
    jmp     spin5

fail_compare_byte:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_compare_byte(%rip), %rsi
    movq    $len_fail_compare_byte, %rdx
    syscall
    movq    $231, %rax
    movq    $6, %rdi
    syscall
spin6:
    jmp     spin6

fail_no_vendor:
    movq    $1, %rax
    movq    $2, %rdi
    leaq    msg_fail_no_vendor(%rip), %rsi
    movq    $len_fail_no_vendor, %rdx
    syscall
    movq    $231, %rax
    movq    $7, %rdi
    syscall
spin7:
    jmp     spin7

    .section .rodata
proc_path: .asciz "/proc/cpuinfo"
dev_path:  .asciz "/dev/cpuinfo"
self_path: .asciz "/proc/self/stat"

msg_open_proc_ok:    .ascii "[proc-translation] /proc/cpuinfo open OK\n"
len_open_proc_ok = . - msg_open_proc_ok

msg_open_dev_ok:     .ascii "[proc-translation] /dev/cpuinfo open OK\n"
len_open_dev_ok = . - msg_open_dev_ok

msg_eq_ok:           .ascii "[proc-translation] /proc/cpuinfo == /dev/cpuinfo OK\n"
len_eq_ok = . - msg_eq_ok

msg_vendor_ok:       .ascii "[proc-translation] vendor line present OK\n"
len_vendor_ok = . - msg_vendor_ok

msg_fail_open_proc:  .ascii "[proc-translation] open(/proc/cpuinfo) FAIL\n"
len_fail_open_proc = . - msg_fail_open_proc

msg_fail_read_proc:  .ascii "[proc-translation] read(/proc/cpuinfo) FAIL\n"
len_fail_read_proc = . - msg_fail_read_proc

msg_fail_open_dev:   .ascii "[proc-translation] open(/dev/cpuinfo) FAIL\n"
len_fail_open_dev = . - msg_fail_open_dev

msg_fail_read_dev:   .ascii "[proc-translation] read(/dev/cpuinfo) FAIL\n"
len_fail_read_dev = . - msg_fail_read_dev

msg_fail_compare_len: .ascii "[proc-translation] length mismatch FAIL\n"
len_fail_compare_len = . - msg_fail_compare_len

msg_fail_compare_byte: .ascii "[proc-translation] byte mismatch FAIL\n"
len_fail_compare_byte = . - msg_fail_compare_byte

msg_fail_no_vendor:  .ascii "[proc-translation] vendor line missing FAIL\n"
len_fail_no_vendor = . - msg_fail_no_vendor

msg_self_ok:         .ascii "[proc-translation] /proc/self/stat open OK\n"
len_self_ok = . - msg_self_ok

msg_fail_open_self:  .ascii "[proc-translation] open(/proc/self/stat) FAIL\n"
len_fail_open_self = . - msg_fail_open_self

msg_fail_read_self:  .ascii "[proc-translation] read(/proc/self/stat) FAIL\n"
len_fail_read_self = . - msg_fail_read_self

msg_fail_self_shape: .ascii "[proc-translation] /proc/self/stat shape FAIL\n"
len_fail_self_shape = . - msg_fail_self_shape

    .section .bss
    .align 8
proc_buf:  .skip 512
dev_buf:   .skip 512
self_buf:  .skip 512
