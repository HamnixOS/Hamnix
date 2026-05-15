PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m2_outb.o

all: m2_outb.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m2_outb.S: m2_outb.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m2-outb/m2_outb.py \
	    -o kernel-modules/m2-outb/m2_outb.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m2_outb.S

.PHONY: all clean
