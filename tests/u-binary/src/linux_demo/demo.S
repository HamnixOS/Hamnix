# tests/u-binary/src/linux_demo/demo.S
#
# A tiny freestanding Linux (SysV/ELF) binary used as the DE
# "Linux Process Viewer" demo app when the heavy musl-busybox
# fixture (tests/u-binary/u_busybox_musl) is absent. It is a REAL
# Linux-ABI binary: it makes raw x86_64 Linux syscalls (write,
# nanosleep, exit_group). Built static-PIE (ET_DYN, no PT_INTERP)
# so Hamnix's elf loader places it at a kernel-chosen load region
# with NO fixed-address kernel-image collision (see the U42 note in
# ../musl_busybox/Makefile). All data is addressed rip-relative, so
# the binary carries ZERO dynamic relocations.
#
# Behaviour: print a banner once, then loop forever printing a
# "tick" line every second — a live, refreshing "process viewer"
# stand-in that proves the DE -> enter-linux launch path exec'd a
# genuine Linux-ns process (serial shows the banner, not
# "command not found").

    .section .text
    .globl _start
_start:
    # write(1, banner, banner_len)
    movq    $1, %rax                # SYS_write
    movq    $1, %rdi                # fd = stdout
    leaq    banner(%rip), %rsi
    movq    $banner_len, %rdx
    syscall

.Lloop:
    # write(1, tick, tick_len)
    movq    $1, %rax
    movq    $1, %rdi
    leaq    tick(%rip), %rsi
    movq    $tick_len, %rdx
    syscall

    # nanosleep(&ts, NULL) — ts = {1s, 0ns}
    movq    $35, %rax               # SYS_nanosleep
    leaq    ts(%rip), %rdi
    xorq    %rsi, %rsi
    syscall

    jmp     .Lloop

    # (never reached, kept so a SIGTERM-less path still exits cleanly)
    movq    $231, %rax              # SYS_exit_group
    xorq    %rdi, %rdi
    syscall

    .section .rodata
banner:
    .ascii  "Hamnix Linux Process Viewer (Linux-ns demo app)\n"
    .ascii  "  running as a real Linux-ABI ELF inside `enter linux`\n"
banner_len = . - banner
tick:
    .ascii  "  tick: process alive\n"
tick_len = . - tick

    .section .data
    .align 8
ts:
    .quad   1                       # tv_sec
    .quad   0                       # tv_nsec
