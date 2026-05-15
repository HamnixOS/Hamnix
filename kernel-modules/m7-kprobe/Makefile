PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m7_kprobe.o

all: m7_kprobe.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m7_kprobe.S: m7_kprobe.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m7-kprobe/m7_kprobe.py \
	    -o kernel-modules/m7-kprobe/m7_kprobe.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m7_kprobe.S

.PHONY: all clean
