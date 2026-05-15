PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m15_die_notifier.o

all: m15_die_notifier.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m15_die_notifier.S: m15_die_notifier.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m15-die-notifier/m15_die_notifier.py \
	    -o kernel-modules/m15-die-notifier/m15_die_notifier.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m15_die_notifier.S

.PHONY: all clean
