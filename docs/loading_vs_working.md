# Loading vs Working — NIC L-shim harness status

> "The product is shim genericity, not per-driver completeness. e1000e
> is the proof-of-concept; every other .ko is a coverage probe. One
> exercise test per subsystem class is enough."
> — feedback_loading_vs_working

## Bar by driver class

| Class | Strict bar | Optional |
|---|---|---|
| NIC (proof-of-concept) | DHCP round-trip via Linux .ko | — |
| NIC (coverage probe) | `init returned 0` with no TRAP/BUG | PCI MATCH + probe rc=0 |
| Storage (proof-of-concept) | mount ext4, read+write file | — |
| Storage (coverage probe) | `init returned 0` with no TRAP/BUG | — |
| USB / audio / wifi etc. | (same coverage-probe bar) | — |

"Loads" = `kmod_linux: name=<mod>` is in the boot log, the loader
applied every relocation, and `kmod_linux: init returned 0` came back.
"Probes" = the driver's `pci_register_driver` walked the bus, matched
its id_table against a live device, and the driver's `probe()` ran to
completion.

## NIC harness — current state (2026-05-25)

| NIC | Driver class | Test script | Result | applied | skipped | init_module | Probe |
|---|---|---|---|---|---|---|---|
| e1000e | Proof-of-concept (Intel 82574-class GbE) | `test_e1000e_tx.sh` | PASS | 12247 | 0 | 0 | rc=0, DHCP ip=10.0.2.15 |
| igb | Coverage (Intel server-class GbE) | `test_igb_ko.sh` | PASS | 11244 | 0 | 0 | **rc=0**, 1 netdev opened |
| r8169 | Coverage (Realtek consumer GbE) | `test_r8169_ko.sh` | PASS | 3536 | 0 | 0 | driver registered, no match |
| atlantic | Coverage (Aquantia/Marvell AQC 10G) | `test_atlantic_ko.sh` | PASS | 14339 | 0 | 0 | driver registered, no match |
| alx | Coverage (Qualcomm Atheros AR816x) | `test_alx_ko.sh` | PASS | 2351 | **1** ⚠ | 0 | driver registered, no match |
| sky2 | Coverage (Marvell Yukon-2) | `test_sky2_ko.sh` | PASS | 2472 | 0 | 0 | driver registered, no match |

### Notes

- **igb is the strongest evidence the L-shim is generic**, not
  e1000e-tuned: `__pci_register_driver` MATCH'd 8086:10c9 on the QEMU
  `-device igb` bus, called probe() with a constructed `pci_dev`, probe
  returned rc=0, and `dev_open` invoked the driver's `ndo_open` which
  also returned 0. This is the full path the e1000e exemplar uses, but
  for a different driver against different silicon IDs.
- **r8169 / atlantic / alx / sky2 register their pci_driver** but no
  matching device is present on the QEMU bus, so `probe()` never fires.
  This is by design — these NICs have no QEMU emulation; load+register
  is the maximum testable surface short of real hardware.
- **alx silent skipped=1** is a known oddity. The L-loader at
  `linux_abi/loader.ad:_sym_addr` silently returns 0 for defined
  symbols whose section index points at a non-SHF_ALLOC section (no
  diagnostic line is emitted, unlike the SHN_UNDEF undefined-external
  path which prints `unresolved external symbol '<name>'`). All 106
  UND symbols of alx.ko are covered by the shim table; the skip is an
  internal cross-reference, not a missing export. The test pins the
  upper bound at `skipped<=1` so a real new gap would trip the assertion.

## Strengthened test pattern

Each NIC's test boots `hamsh` as `/init`, drives `insmod /lib/modules/
<name>.ko` from the shell, snapshots the printk ring via `dmesg`, and
asserts on the NIC-specific section of the log:

1. `kmod_linux: name=<name>` — the .ko bytes were located + parsed.
2. `kmod_linux: relocations applied=N skipped=0` (skipped<=1 for alx).
3. `kmod_linux: init returned 0`.
4. No `insmod: init_module failed` from userspace.
5. No TRAP / BUG / PANIC / invalid opcode anywhere in the boot.
6. No `unresolved external symbol` / `unknown reloc type` diagnostics.
7. (igb only) `pci_register_driver MATCH` + `probe returned rc=0`.

This is materially stronger than the previous pattern (which only
verified the kernel built and reached early boot, without ever
loading the target NIC's .ko). The previous tests would have passed
trivially even if the NIC's shim coverage was broken — the new tests
will not.

## Failure modes intentionally NOT covered

- Real packet TX/RX through a non-e1000e NIC (no matching QEMU
  emulation for alx/atlantic/sky2; no real hardware in CI).
- DHCP round-trip via igb / r8169 — possible in principle but requires
  the `linux_tx_bridge` to bind to the second netdev. Out of scope per
  the loading-vs-working principle.
- Live-hardware bring-up. The L-shim's job is to load these drivers
  CLEANLY; if a real machine has an `alx` NIC, the driver should claim
  it via the same path that igb claims its QEMU device. There is no
  way to assert that in CI; the proof is the shim's structure.

## When to add an NIC test

Whenever a new stock Linux NIC .ko is dropped into `kernel-modules/<name>/`:

1. Add the `_add_export()` rows for any UND symbols not yet in
   `linux_abi/exports.ad` (see `scripts/test_<name>_ko.sh`'s gap diag
   for the canonical missing-list query).
2. Copy `scripts/test_atlantic_ko.sh` as a template; replace the NIC
   name everywhere.
3. Add a row to the table above.
4. If the NIC has matching QEMU emulation (rare!), add MATCH + probe
   assertions like `test_igb_ko.sh`'s.

The test must drive `insmod` through hamsh — bake-but-don't-load tests
are weak and silently let symbol gaps in.
