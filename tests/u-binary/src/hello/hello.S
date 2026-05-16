.section .text
.globl _start
_start:
    # write(1, msg, msg_len)
    movq $1, %rax            # SYS_write
    movq $1, %rdi            # fd
    leaq msg(%rip), %rsi
    movq $msg_len, %rdx
    syscall

    # exit_group(0)
    movq $231, %rax          # SYS_exit_group
    xorq %rdi, %rdi
    syscall

.section .rodata
msg: .ascii "U5: hello from a Linux ELF\n"
msg_len = . - msg
