# tests/linux-modules/src/hello/Makefile — stock Linux kbuild.
#
# Build with `make -C tests/linux-modules/src/hello`. The result is
# hello.ko in this directory, which the parent's `make install` step
# copies up to tests/linux-modules/hello.ko (the L1 test fixture).
#
# KDIR points at a Linux source tree built against the pinned ABI
# target (Linux 6.12.48; see linux_abi/TARGET_ABI.md). Override
# KDIR on the command line to point at a different tree:
#     make KDIR=/path/to/linux-6.12.48

KDIR ?= /lib/modules/$(shell uname -r)/build

obj-m += hello.o

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install: all
	cp hello.ko ../../hello.ko
