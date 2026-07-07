# tests/u-binary/src/ipc_child/Makefile -- exec'd child half of the
# inherited-fd IPC test. Output: ../../u_ipc_child, a static-PIE ELF64
# (ET_DYN, no PT_INTERP) that the ipc_forkexec parent's fork-child
# execve()s into. It reads/writes over the pipe + socketpair fds it
# inherited across fork+exec (fd numbers handed in on argv).

CC      := cc
HAS_CC  := $(shell command -v $(CC) 2>/dev/null)

CAN_SPIE := $(shell printf 'int main(void){return 0;}\n' > /tmp/.ipcch_probe.c && \
                  $(CC) -static-pie -O2 -o /tmp/.ipcch_probe /tmp/.ipcch_probe.c >/dev/null 2>&1 && \
                  echo yes || echo no)

hello: hello.c
ifeq ($(HAS_CC),)
	@echo "[ipc_child] SKIP: no host C compiler ($(CC)) found"
else
ifeq ($(CAN_SPIE),no)
	@echo "[ipc_child] SKIP: $(CC) -static-pie failed (libc.a missing?)"
else
	$(CC) -static-pie -O2 -o hello hello.c
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif
endif

install: hello
ifeq ($(HAS_CC),)
	@echo "[ipc_child] SKIP install (no host C compiler)"
else
ifeq ($(CAN_SPIE),no)
	@echo "[ipc_child] SKIP install (no static-pie glibc)"
else
	cp hello ../../u_ipc_child
endif
endif

clean:
	rm -f hello hello.o
