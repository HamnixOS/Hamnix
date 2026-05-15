PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m3_proc.o

all: m3_proc.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m3_proc.S: m3_proc.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m3-proc/m3_proc.py \
	    -o kernel-modules/m3-proc/m3_proc.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m3_proc.S

.PHONY: all clean
