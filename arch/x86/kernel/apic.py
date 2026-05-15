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


# --- PIT-anchored LAPIC timer calibration --------------------------
#
# Mirrors arch/x86/kernel/apic/apic.c::calibrate_APIC_clock(). Run
# the LAPIC timer counting down from max (0xFFFFFFFF) while gating
# PIT channel 2 on for a 10 ms one-shot interval. When the PIT's
# OUT line (visible on port 0x61 bit 4) goes high, sample the LAPIC
# current count. The difference from the starting max is the number
# of LAPIC ticks elapsed in 10 ms, which we scale to a periodic
# initial count for our target HZ (100).
#
# PIT channel 2 is the speaker-tied channel; bit 0 of port 0x61
# gates its counting and bit 1 connects/disconnects the speaker.
# We toggle the gate and ignore the speaker.

PIT_CH2_DATA:  int32 = 0x42
PIT_CMD:       int32 = 0x43
PIT_CTRL:      int32 = 0x61

# Command byte: channel 2 (bits 7..6 = 10), lobyte/hibyte (bits 5..4 =
# 11), mode 0 = one-shot (bits 3..1 = 000), binary (bit 0 = 0) = 0xB0.
PIT_CMD_CH2_ONESHOT: int32 = 0xB0

# PIT runs at 1193182 Hz. Divisor for a 10 ms interval = 11932 = 0x2E9C.
PIT_10MS_DIVISOR: int32 = 0x2E9C

# Port 0x61:
#   bit 0  speaker timer GATE2  (1 = let channel 2 count)
#   bit 1  speaker enable        (cosmetic for us)
#   bit 4  OUT pin status        (1 once channel 2 reaches 0)
PIT_CTRL_GATE:  int32 = 0x01
PIT_CTRL_SPEAK: int32 = 0x02
PIT_CTRL_OUT:   int32 = 0x10

# Target tick rate. Matches what we used to assume; if you tune this
# the only consequence is the periodic count divisor.
TIMER_HZ: uint64 = 100


def _pit_gate_off():
    # Stop channel 2 + ensure speaker is off so we don't beep.
    cur: int32 = inb(PIT_CTRL)
    outb(cur & ~(PIT_CTRL_GATE | PIT_CTRL_SPEAK), PIT_CTRL)


def _pit_gate_on():
    cur: int32 = inb(PIT_CTRL)
    outb((cur & ~PIT_CTRL_SPEAK) | PIT_CTRL_GATE, PIT_CTRL)


def lapic_calibrate_and_setup_timer():
    # Step 1: stop / mask everything first.
    _lapic_write(LAPIC_LVT_TIMER_REG, 0x10000)         # bit 16 = mask
    _pit_gate_off()

    # Step 2: program PIT channel 2 for 10 ms one-shot.
    outb(PIT_CMD_CH2_ONESHOT, PIT_CMD)
    outb(PIT_10MS_DIVISOR & 0xFF, PIT_CH2_DATA)
    outb((PIT_10MS_DIVISOR >> 8) & 0xFF, PIT_CH2_DATA)

    # Step 3: arm LAPIC timer at max (will count down freely with
    # divide=16; mask is still set so no IRQ fires).
    _lapic_write(LAPIC_TIMER_DIVIDE, TIMER_DIVIDE_16)
    _lapic_write(LAPIC_TIMER_INIT, 0xFFFFFFFF)

    # Step 4: open the PIT gate to start counting. The LAPIC timer
    # has been counting all along but the reference point is "right
    # now" — both counters are running synchronously.
    _pit_gate_on()

    # Step 5: poll OUT pin until PIT expires (10 ms wall-clock).
    while (inb(PIT_CTRL) & PIT_CTRL_OUT) == 0:
        pass

    # Step 6: snapshot LAPIC's current count; the delta from max is
    # the number of LAPIC ticks (post-divide-by-16) that fit in 10 ms.
    cur: uint32 = _lapic_read(LAPIC_TIMER_CUR)
    elapsed: uint32 = 0xFFFFFFFF - cur

    # Tidy up: stop the PIT so it doesn't keep gating.
    _pit_gate_off()

    # Step 7: scale to ticks_per_second + program periodic initial
    # count for the desired HZ. elapsed corresponds to 10 ms, so
    # ticks_per_second = elapsed × 100, and the periodic count for
    # HZ = 100 is exactly `elapsed`.
    ticks_per_second: uint64 = cast[uint64](elapsed) * 100
    periodic_count: uint32   = elapsed * cast[uint32](100) / cast[uint32](TIMER_HZ)

    printk1("LAPIC: calibration measured %d Hz (post-÷16)\n",
            ticks_per_second)
    printk1("LAPIC: programming periodic count = %d (target 100 Hz)\n",
            cast[uint64](periodic_count))

    _lapic_write(LAPIC_LVT_TIMER_REG, TIMER_VECTOR | LVT_PERIODIC)
    _lapic_write(LAPIC_TIMER_INIT,    periodic_count)


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
