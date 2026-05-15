PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m7_crypto.o

all: m7_crypto.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m7_crypto.S: m7_crypto.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m7-crypto/m7_crypto.py \
	    -o kernel-modules/m7-crypto/m7_crypto.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m7_crypto.S

.PHONY: all clean
