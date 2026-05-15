PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m8_atomic.o

all: m8_atomic.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m8_atomic.S: m8_atomic.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m8-atomic/m8_atomic.py \
	    -o kernel-modules/m8-atomic/m8_atomic.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m8_atomic.S

.PHONY: all clean
