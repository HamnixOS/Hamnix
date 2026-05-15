PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m2_string.o

all: m2_string.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m2_string.S: m2_string.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m2-string/m2_string.py \
	    -o kernel-modules/m2-string/m2_string.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m2_string.S

.PHONY: all clean
