# tests/u-binary/src/musl_signal/Makefile -- U31 fixture build.
#
# Builds a musl-gcc static-PIE x86_64 ELF that exercises Hamnix's
# new signal()/kill()/SIGUSR1 delivery path. Output is staged at
# tests/u-binary/u_musl_signal so build_initramfs.py embeds it at
# /bin/u_musl_signal.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

hello: hello.c
ifeq ($(MUSL_GCC),)
	@echo "[musl_signal] SKIP: musl-gcc not installed."
	@echo "[musl_signal]   apt-get install -y musl-tools (needs sudo)"
else
	# -pthread is intentionally NOT passed: it changes musl's TCB
	# bring-up to use pthread-aware setjmp/longjmp + pulls in
	# pthread_create even though signal() itself doesn't need
	# threads. U31's reduced surface (no FUTEX_REQUEUE from the
	# thread-aware startup) keeps the test focused on the signal
	# path alone.
	$(MUSL_GCC) -static-pie -O2 -o hello hello.c
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: hello
ifeq ($(MUSL_GCC),)
	@echo "[musl_signal] SKIP install (no musl-gcc, nothing built)"
else
	cp hello ../../u_musl_signal
endif

clean:
	rm -f hello hello.o
