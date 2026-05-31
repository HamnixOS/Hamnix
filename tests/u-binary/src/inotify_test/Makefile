# tests/u-binary/src/inotify_test/Makefile — #155 fixture build.
#
# Builds a musl-gcc static-PIE x86_64 ELF that exercises the inotify
# surface: inotify_init1 / inotify_add_watch on /tmp, then create +
# modify + delete a file and read() the resulting struct inotify_event
# records. Staged at tests/u-binary/u_inotify_test -> /bin/u_inotify_test.
# SKIPs quietly if musl-gcc isn't installed.

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

inotify_test: inotify_test.c
ifeq ($(MUSL_GCC),)
	@echo "[inotify_test] SKIP: musl-gcc not installed."
	@echo "[inotify_test]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -o inotify_test inotify_test.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3).
	printf '\003' | dd of=inotify_test bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: inotify_test
ifeq ($(MUSL_GCC),)
	@echo "[inotify_test] SKIP install (no musl-gcc, nothing built)"
else
	cp inotify_test ../../u_inotify_test
endif

clean:
	rm -f inotify_test inotify_test.o
