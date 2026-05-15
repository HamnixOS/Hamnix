PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m9_task.o

all: m9_task.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m9_task.S: m9_task.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m9-task/m9_task.py \
	    -o kernel-modules/m9-task/m9_task.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m9_task.S

.PHONY: all clean
