# arch/x86/kernel/apic.py
#
# Mirrors arch/x86/kernel/apic/apic.c in Linux at minimal scope: brings
# the boot CPU's Local APIC online and (re)points the timer through it.
# The legacy 8259 PIC is masked off — APIC is the only interrupt
# controller from this point on. SMP bring-up of secondary CPUs is the
# next milestone; this one is the prerequisite (every AP also has its
# own LAPIC and we need ours working first).
#
# LAPIC access is via MMIO at the physical address held in the
# IA32_APIC_BASE MSR (default 0xFEE00000, never moved in practice).
# arch/x86/boot/header.S identity-maps the first 4 GiB with 1 GiB
# pages so the MMIO window is reachable without extra page-table work.
#
# Registers we touch (offsets from LAPIC base):
#
#   0x020  APIC ID                (read-only)
#   0x030  APIC Version
#   0x0B0  End Of Interrupt       (write any value)
#   0x0F0  Spurious Interrupt Vector Register (SVR)
#                                    bit 8  = APIC software-enable
#                                    bits 0..7 = spurious vector
#   0x320  LVT Timer
#                                    bits 0..7 = vector
#                                    bit 17 = periodic mode
#                                    bit 16 = masked
#   0x380  Timer Initial Count
#   0x390  Timer Current Count
#   0x3E0  Timer Divide Configuration  (0x3 = divide-by-16)
#
# Initial count is hand-picked (5_000_000); on QEMU TCG that lands the
# timer somewhere in the few-tens-of-Hz range — plenty to drive
# preemption visibly. Real Linux calibrates LAPIC ticks-per-second
# against PIT/HPET on boot; we'll port that once we want stable HZ.

from kernel.printk.printk import printk0, printk1

extern def read_msr(index: uint32) -> uint64
extern def write_msr(index: uint32, value: uint64)

IA32_APIC_BASE_MSR: uint32 = 0x1B
APIC_BASE_ENABLE:   uint64 = 0x800             # bit 11

LAPIC_PHYS_BASE: uint64 = 0xFEE00000

# Register offsets
LAPIC_ID_REG:        uint64 = 0x020
LAPIC_VERSION_REG:   uint64 = 0x030
LAPIC_EOI_REG:       uint64 = 0x0B0
LAPIC_SVR_REG:       uint64 = 0x0F0
LAPIC_LVT_TIMER_REG: uint64 = 0x320
LAPIC_TIMER_INIT:    uint64 = 0x380
LAPIC_TIMER_CUR:     uint64 = 0x390
LAPIC_TIMER_DIVIDE:  uint64 = 0x3E0

# SVR bits
SVR_ENABLE: uint32 = 0x100

# LVT Timer bits
LVT_PERIODIC: uint32 = 0x20000

# Timer wiring: route LAPIC timer through IDT vector 32 — the same
# vector PIT used, so do_irq() still routes to timer_interrupt() and
# no other code needs to change.
TIMER_VECTOR:     uint32 = 32
SPURIOUS_VECTOR:  uint32 = 0xFF

# Divide configuration register encoding: 0x3 == divide by 16.
TIMER_DIVIDE_16:  uint32 = 0x3

# Hand-picked initial count. On QEMU TCG produces visible preemption
# without overwhelming the serial output.
TIMER_INITIAL_COUNT: uint32 = 5000000


def _lapic_read(off: uint64) -> uint32:
    return cast[Ptr[uint32]](LAPIC_PHYS_BASE + off)[0]


def _lapic_write(off: uint64, value: uint32):
    cast[Ptr[uint32]](LAPIC_PHYS_BASE + off)[0] = value


def apic_enable():
    # Flip the global-enable bit. Linux also reads back to verify;
    # we trust the write since QEMU honours it.
    v: uint64 = read_msr(IA32_APIC_BASE_MSR)
    write_msr(IA32_APIC_BASE_MSR, v | APIC_BASE_ENABLE)


def apic_init():
    # Linux's setup_local_APIC() does a great deal more — TPR clear,
    # ESR clear, LVT LINT0/LINT1 program, PERF/THERM masks. For M16.22
    # we set just the SVR (mandatory to take any interrupts at all),
    # since the LVT entries default to MASKED at reset.
    apic_enable()

    apic_id:  uint32 = _lapic_read(LAPIC_ID_REG) >> 24
    apic_ver: uint32 = _lapic_read(LAPIC_VERSION_REG) & 0xFF
    printk1("LAPIC: id=%d ", cast[uint64](apic_id))
    printk1("version=0x%x\n", cast[uint64](apic_ver))

    # Software-enable the APIC and pick a spurious vector. Without
    # this bit set the LAPIC ignores all incoming IPIs / LVT events.
    _lapic_write(LAPIC_SVR_REG, SVR_ENABLE | SPURIOUS_VECTOR)


def lapic_setup_timer():
    # Periodic mode at TIMER_VECTOR. Mode + vector go to LVT Timer
    # first (the timer is masked); divide config and initial count
    # arm it.
    _lapic_write(LAPIC_LVT_TIMER_REG, TIMER_VECTOR | LVT_PERIODIC)
    _lapic_write(LAPIC_TIMER_DIVIDE,  TIMER_DIVIDE_16)
    _lapic_write(LAPIC_TIMER_INIT,    TIMER_INITIAL_COUNT)
    printk1("LAPIC: timer armed, initial count = %d\n",
            cast[uint64](TIMER_INITIAL_COUNT))


def lapic_send_eoi():
    # Linux's apic_eoi() is one MMIO write to EOI. Any value works;
    # the LAPIC reads the WRITE to advance the in-service register.
    _lapic_write(LAPIC_EOI_REG, 0)


# --- IPI sending ---------------------------------------------------
#
# The Interrupt Command Register lives at offsets 0x300 (low 32 bits)
# and 0x310 (high 32 bits). Writing to 0x300 triggers the IPI; the
# destination APIC ID goes in the high register's bits 24..31. We
# write high first (it doesn't fire anything) then low (which does).
#
# Bit fields in ICR low:
#   bits  0..7   vector
#   bits  8..10  delivery mode (0 = fixed, 5 = INIT, 6 = startup)
#   bit  11      destination mode (0 = physical)
#   bit  12      delivery status (read-only)
#   bit  14      level (1 = assert)
#   bit  15      trigger mode (0 = edge)
#   bits 18..19  destination shorthand (0 = use APIC ID)
#
# INIT IPI: delivery_mode=5, level=1, trigger=0
#           value = (1 << 14) | (5 << 8)            = 0x4500
# STARTUP IPI: delivery_mode=6, vector=V, level=1, trigger=0
#              value = (1 << 14) | (6 << 8) | V    = 0x4600 | V
# Linux uses the same magic numbers (apic.c::apic_icr_write).

LAPIC_ICR_LOW:  uint64 = 0x300
LAPIC_ICR_HIGH: uint64 = 0x310

ICR_INIT_LEVEL:    uint32 = 0x4500
ICR_STARTUP_BASE:  uint32 = 0x4600
ICR_DELIVERY_BUSY: uint32 = 0x1000          # bit 12


def _lapic_wait_icr_idle():
    # Bit 12 of ICR_LOW reads "delivery pending". Spin briefly.
    while (_lapic_read(LAPIC_ICR_LOW) & ICR_DELIVERY_BUSY) != 0:
        pass


def lapic_send_init(target_apic_id: uint32):
    # INIT IPI to a specific AP. Halts the AP in a state ready for
    # the subsequent SIPI. Linux follows this with a 10 ms wait.
    _lapic_write(LAPIC_ICR_HIGH, target_apic_id << 24)
    _lapic_write(LAPIC_ICR_LOW, ICR_INIT_LEVEL)
    _lapic_wait_icr_idle()


def lapic_send_sipi(target_apic_id: uint32, vector: uint32):
    # Startup IPI carrying the 8-bit "start vector" V. The AP begins
    # executing at physical CS:IP = (V<<8):0000 = V*0x1000 in 16-bit
    # real mode. Spec says BSP should send TWO SIPIs spaced 200 µs
    # apart; we send one and rely on QEMU's deterministic emulation.
    _lapic_write(LAPIC_ICR_HIGH, target_apic_id << 24)
    _lapic_write(LAPIC_ICR_LOW, ICR_STARTUP_BASE | (vector & 0xFF))
    _lapic_wait_icr_idle()
