PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m11_debugfs.o

all: m11_debugfs.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m11_debugfs.S: m11_debugfs.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m11-debugfs/m11_debugfs.py \
	    -o kernel-modules/m11-debugfs/m11_debugfs.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m11_debugfs.S

.PHONY: all clean
