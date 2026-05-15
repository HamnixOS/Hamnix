PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m6_slab.o

all: m6_slab.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m6_slab.S: m6_slab.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m6-slab/m6_slab.py \
	    -o kernel-modules/m6-slab/m6_slab.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m6_slab.S

.PHONY: all clean
