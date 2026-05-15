PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m9_list.o

all: m9_list.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m9_list.S: m9_list.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m9-list/m9_list.py \
	    -o kernel-modules/m9-list/m9_list.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m9_list.S

.PHONY: all clean
