# tests/u-binary/src/glib_selfwake/Makefile
#
# GLib GMainContext cross-thread self-wake regression fixture. Same build
# shape as sem_pingpong/Makefile: static-PIE musl ELF64, OSABI stamped Linux.
#
# Output: ../../u_glib_selfwake

MUSL_GCC := $(shell command -v musl-gcc 2>/dev/null)

hello: hello.c
ifeq ($(MUSL_GCC),)
	@echo "[glib_selfwake] SKIP: musl-gcc not installed."
	@echo "[glib_selfwake]   apt-get install -y musl-tools (needs sudo)"
else
	$(MUSL_GCC) -static-pie -O2 -pthread -o hello hello.c
	printf '\003' | dd of=hello bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif

install: hello
ifeq ($(MUSL_GCC),)
	@echo "[glib_selfwake] SKIP install (no musl-gcc, nothing built)"
else
	cp hello ../../u_glib_selfwake
endif

clean:
	rm -f hello hello.o
