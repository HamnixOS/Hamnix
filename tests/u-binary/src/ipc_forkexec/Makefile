# tests/u-binary/src/ipc_forkexec/Makefile -- inherited-fd IPC parent.
#
# Output: ../../u_ipc_forkexec -- a static-PIE ELF64 (ET_DYN, no
# PT_INTERP, no ld.so) that creates a pipe pair + socketpair, fork()s,
# and has the child execve() /bin/u_ipc_child inheriting those fds. It
# then round-trips a message both directions over both transports.
# Reproduces the Firefox parent<->content cross-process IPC handshake
# in the smallest possible static form (no threads, no ld.so, no PTY).

CC      := cc
HAS_CC  := $(shell command -v $(CC) 2>/dev/null)

CAN_SPIE := $(shell printf 'int main(void){return 0;}\n' > /tmp/.ipcfe_probe.c && \
                  $(CC) -static-pie -O2 -o /tmp/.ipcfe_probe /tmp/.ipcfe_probe.c >/dev/null 2>&1 && \
                  echo yes || echo no)

hello: hello.c
ifeq ($(HAS_CC),)
	@echo "[ipc_forkexec] SKIP: no host C compiler ($(CC)) found"
else
ifeq ($(CAN_SPIE),no)
	@echo "[ipc_forkexec] SKIP: $(CC) -static-pie failed (libc.a missing?)"
else
	$(CC) -static-pie -O2 -o hello hello.c
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif
endif

install: hello
ifeq ($(HAS_CC),)
	@echo "[ipc_forkexec] SKIP install (no host C compiler)"
else
ifeq ($(CAN_SPIE),no)
	@echo "[ipc_forkexec] SKIP install (no static-pie glibc)"
else
	cp hello ../../u_ipc_forkexec
endif
endif

clean:
	rm -f hello hello.o
