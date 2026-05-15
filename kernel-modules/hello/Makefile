# kbuild wrapper for the Pynux hello-world kernel module (milestone M1).
#
# The Pynux compiler emits hello.S; the Linux kernel build system (kbuild)
# owns assembly + link + modpost, turning hello.S into a loadable hello.ko.
# We do not invoke `as`/`ld` ourselves — this avoids host-vs-kernel
# assembler-flag mismatch.
#
# KDIR defaults to the custom mitigations-off kernel built by
# scripts/build_x86_kernel.sh, but can be overridden, e.g. to smoke-test
# against the running distro kernel:
#   make KDIR=/lib/modules/$(uname -r)/build

PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := hello.o

all: hello.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

hello.S: hello.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/hello/hello.py \
	    -o kernel-modules/hello/hello.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f hello.S

.PHONY: all clean
