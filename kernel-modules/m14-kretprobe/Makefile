PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m14_kretprobe.o

all: m14_kretprobe.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m14_kretprobe.S: m14_kretprobe.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m14-kretprobe/m14_kretprobe.py \
	    -o kernel-modules/m14-kretprobe/m14_kretprobe.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m14_kretprobe.S

.PHONY: all clean
