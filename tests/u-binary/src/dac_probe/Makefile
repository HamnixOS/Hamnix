# tests/u-binary/src/dac_probe/Makefile -- Linux-NS DAC probe fixture.
#
# Same pattern as glibc_idprobe: host-built static-PIE ELF, stamped with
# OSABI=Linux (3), copied to ../../u_dac_probe for build_initramfs.py to
# pick up as /bin/u_dac_probe.
#
# REQUIRES: host cc + libc6-dev (static glibc + Scrt1.o). If the host
# toolchain can't link -static-pie the install step prints a skip note
# and exits 0 so CI without the host static-glibc still passes.

CC      := cc
HAS_CC  := $(shell command -v $(CC) 2>/dev/null)

CAN_SPIE := $(shell printf 'int main(void){return 0;}\n' > /tmp/.dac_probe.c && \
                  $(CC) -static-pie -O2 -o /tmp/.dac_probe /tmp/.dac_probe.c >/dev/null 2>&1 && \
                  echo yes || echo no)

dac: dac.c
ifeq ($(HAS_CC),)
	@echo "[dac_probe] SKIP: no host C compiler ($(CC)) found"
else
ifeq ($(CAN_SPIE),no)
	@echo "[dac_probe] SKIP: $(CC) -static-pie failed (libc.a / Scrt1.o missing?)"
	@echo "[dac_probe]   apt-get install -y libc6-dev  # (needs sudo)"
else
	$(CC) -static-pie -O2 -o dac dac.c
	# Stamp e_ident[EI_OSABI] = ELFOSABI_LINUX (3) so Hamnix's U1 detect
	# path takes the Linux branch without ambiguity.
	printf '\003' | dd of=dac bs=1 seek=7 count=1 conv=notrunc 2>/dev/null
endif
endif

install: dac
ifeq ($(HAS_CC),)
	@echo "[dac_probe] SKIP install (no host C compiler)"
else
ifeq ($(CAN_SPIE),no)
	@echo "[dac_probe] SKIP install (no static-pie glibc)"
else
	cp dac ../../u_dac_probe
endif
endif

clean:
	rm -f dac dac.o
