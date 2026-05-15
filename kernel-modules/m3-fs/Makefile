PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m3_fs.o

all: m3_fs.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m3_fs.S: m3_fs.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m3-fs/m3_fs.py \
	    -o kernel-modules/m3-fs/m3_fs.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m3_fs.S

.PHONY: all clean
