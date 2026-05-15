PYNUX     ?= python3 -m compiler.pynux
KDIR      ?= $(HOME)/pynux-kernel/linux
PWD       := $(shell pwd)
PROJ_ROOT := $(abspath $(PWD)/../..)

obj-m := m9_socket.o

all: m9_socket.S
	$(MAKE) -C $(KDIR) M=$(PWD) modules

m9_socket.S: m9_socket.py
	cd $(PROJ_ROOT) && $(PYNUX) compile \
	    --target=x86_64-linux-kernel-module \
	    kernel-modules/m9-socket/m9_socket.py \
	    -o kernel-modules/m9-socket/m9_socket.S

clean:
	-$(MAKE) -C $(KDIR) M=$(PWD) clean
	rm -f m9_socket.S

.PHONY: all clean
