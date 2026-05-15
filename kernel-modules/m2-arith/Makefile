# kbuild wrapper for the Pynux M2.0 arithmetic test module.
# See kernel-modules/hello/Makefile for the overall pattern.

PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m2_arith.o

all: m2_arith.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m2_arith.S: m2_arith.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m2-arith/m2_arith.py \
	    -o kernel-modules/m2-arith/m2_arith.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m2_arith.S

.PHONY: all clean
