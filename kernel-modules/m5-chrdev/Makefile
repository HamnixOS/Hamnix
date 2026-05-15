PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m5_chrdev.o

all: m5_chrdev.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m5_chrdev.S: m5_chrdev.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m5-chrdev/m5_chrdev.py \
	    -o kernel-modules/m5-chrdev/m5_chrdev.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m5_chrdev.S

.PHONY: all clean
