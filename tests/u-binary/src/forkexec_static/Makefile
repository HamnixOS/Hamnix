# tests/u-binary/src/forkexec_static/Makefile -- QA-N29 minimal
# fork+execve repro. Output: ../../u_forkexec_static, a static-PIE
# ELF64 (ET_DYN, no PT_INTERP) that fork()s and execve()s
# /bin/u_glibc_hello in the child. No ld.so, no PTY, no threads.

CC      := cc
HAS_CC  := $(shell command -v $(CC) 2>/dev/null)

CAN_SPIE := $(shell printf 'int main(void){return 0;}\n' > /tmp/.fes_probe.c && \
                  $(CC) -static-pie -O2 -o /tmp/.fes_probe /tmp/.fes_probe.c >/dev/null 2>&1 && \
                  echo yes || echo no)

hello: hello.c
ifeq ($(HAS_CC),)
	@echo "[forkexec_static] SKIP: no host C compiler ($(CC)) found"
else
ifeq ($(CAN_SPIE),no)
	@echo "[forkexec_static] SKIP: $(CC) -static-pie failed (libc.a missing?)"
else
	$(CC) -static-pie -O2 -o hello hello.c
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif
endif

install: hello
ifeq ($(HAS_CC),)
	@echo "[forkexec_static] SKIP install (no host C compiler)"
else
ifeq ($(CAN_SPIE),no)
	@echo "[forkexec_static] SKIP install (no static-pie glibc)"
else
	cp hello ../../u_forkexec_static
endif
endif

clean:
	rm -f hello hello.o
