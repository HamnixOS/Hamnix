PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m6_sync.o

all: m6_sync.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m6_sync.S: m6_sync.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m6-sync/m6_sync.py \
	    -o kernel-modules/m6-sync/m6_sync.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m6_sync.S

.PHONY: all clean
