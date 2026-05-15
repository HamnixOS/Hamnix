PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m2_console.o

all: m2_console.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m2_console.S: m2_console.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m2-console/m2_console.py \
	    -o kernel-modules/m2-console/m2_console.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m2_console.S

.PHONY: all clean
