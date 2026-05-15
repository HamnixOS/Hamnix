PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m4_kthread_wq.o

all: m4_kthread_wq.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m4_kthread_wq.S: m4_kthread_wq.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m4-kthread-wq/m4_kthread_wq.py \
	    -o kernel-modules/m4-kthread-wq/m4_kthread_wq.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m4_kthread_wq.S

.PHONY: all clean
