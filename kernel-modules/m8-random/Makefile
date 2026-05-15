PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m8_random.o

all: m8_random.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m8_random.S: m8_random.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m8-random/m8_random.py \
	    -o kernel-modules/m8-random/m8_random.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m8_random.S

.PHONY: all clean
