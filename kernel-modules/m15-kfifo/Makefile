PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m15_kfifo.o

all: m15_kfifo.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m15_kfifo.S: m15_kfifo.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m15-kfifo/m15_kfifo.py \
	    -o kernel-modules/m15-kfifo/m15_kfifo.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m15_kfifo.S

.PHONY: all clean
