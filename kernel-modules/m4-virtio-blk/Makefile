PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m4_virtio_blk.o

all: m4_virtio_blk.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m4_virtio_blk.S: m4_virtio_blk.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m4-virtio-blk/m4_virtio_blk.py \
	    -o kernel-modules/m4-virtio-blk/m4_virtio_blk.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m4_virtio_blk.S

.PHONY: all clean
