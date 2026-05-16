# tests/linux-modules/src/hrtimer/Makefile - stock Linux kbuild.
#
# Build with `make -C tests/linux-modules/src/hrtimer`. The result is
# hrtimer.ko in this directory, which the `make install` step copies
# up to tests/linux-modules/hrtimer.ko (the L10 test fixture).
#
# KDIR points at a Linux source tree built against the pinned ABI
# target (Linux 6.12.48; see linux_abi/TARGET_ABI.md). Override
# KDIR on the command line to point at a different tree:
#     make KDIR=/path/to/linux-6.12.48

KDIR ?= /lib/modules/$(shell uname -r)/build

obj-m += hrtimer.o

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install: all
	cp hrtimer.ko ../../hrtimer.ko
