PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m14_syscall.o

all: m14_syscall.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m14_syscall.S: m14_syscall.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m14-syscall/m14_syscall.py \
	    -o kernel-modules/m14-syscall/m14_syscall.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m14_syscall.S

.PHONY: all clean
