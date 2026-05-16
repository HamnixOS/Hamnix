# L-track expected output contract

This file documents the per-fixture (marker_string) contract that
`scripts/test_l_track.sh` asserts. It is the single source of truth
for "what does it mean for fixture <name>.ko to PASS?"

`test_l_track.sh` currently hardcodes a subset of this table in its
`MARKERS=()` associative array. As new fixtures land or new printk
markers are added, this file is updated first; the script's MARKERS
array is then expanded to match.

## Contract

For each fixture `<name>.ko`:

  1. The Hamnix L1 loader applies relocations, resolves UND symbols
     via `linux_abi/exports.ad`, and dispatches `module_init`.
  2. `module_init` runs and calls `printk(KERN_INFO ...)` with a
     string starting `L<N>: <name>.ko module_init`, where `<N>` is
     the milestone the fixture exercises.
  3. The L1 printk shim (`_linux_printk_shim` in `exports.ad`)
     forwards that string to `printk0`, which lands on the serial
     console captured by QEMU's `-serial stdio`.
  4. `scripts/test_l_track.sh` greps the captured log for the
     marker string. Presence == PASS.

A few fixtures (proc, chrdev, fs, netdev, pci, socket, virtio) use
a per-API success line rather than the canonical `<N>: <name>.ko
module_init` pattern. Those rows note the actual marker.

## Marker table

| L# | Fixture  | Marker string (grep -F target)                  | Notes |
|----|----------|--------------------------------------------------|-------|
| L1 | hello    | `L1: hello.ko module_init`                       | printk only |
| L3 | slab     | `L3: slab.ko module_init`                        | kmem_cache_* |
| L4 | chrdev   | `L4: chrdev registered`                          | register_chrdev success line |
| L5 | proc     | `L5: proc_create returned`                       | proc_create returned a non-NULL entry |
| L6 | sync     | `L6: sync.ko module_init`                        | mutex/spinlock/completion |
| L7 | waitq    | `L7: waitq.ko module_init`                       | wait_queue_head_t |
| L8 | workq    | `L8: workq.ko module_init`                       | workqueue + delayed_work |
| L9 | timer    | `L9: timer.ko module_init`                       | timer_list |
| L10 | hrtimer | `L10: hrtimer.ko module_init`                    | hrtimer |
| L11 | irq     | `L11: irq.ko module_init`                        | request_irq path |
| L12 | sysfs   | `L12: sysfs.ko module_init`                      | kobject + attribute |
| L13 | kprobe  | `L13: kprobe.ko module_init`                     | register_kprobe |
| L14 | debugfs | `L14: debugfs.ko module_init`                    | debugfs_create_* |
| L15 | crypto  | `L15: crypto.ko module_init`                     | crypto_alloc_shash |
| L16 | random  | `L16: random.ko module_init`                     | get_random_bytes + copy_to_user |
| L17 | atomic  | `L17: atomic.ko module_init`                     | atomic_t ops |
| L18 | utsname | `L18: utsname.ko module_init`                    | init_uts_ns |
| L21 | pci     | `L21: pci registered`                            | pci_register_driver success |
| L22 | dma     | `L22: dma.ko module_init`                        | dma_alloc_coherent |
| L23 | virtio  | `L23: virtio registered`                         | register_virtio_driver success |
| L25 | netdev  | `L25: netdev registered`                         | register_netdev success |
| L27 | fs      | `L27: fs registered`                             | register_filesystem success |
| L28 | socket  | `L28: socket ok`                                 | sock_create_kern success |

## Skipped / placeholder fixtures

The following `src/<name>/` directories are reserved for future
milestones but currently have no `.c` source. They are SKIPped by
`test_l_track.sh` (no marker, no fixture binary):

  * `block`   — L24 block layer (planned)
  * `die`     — L20 die_notifier (planned)
  * `list`    — L19 list.h macros (planned)

When a placeholder grows a real fixture, add a row to the table
above (with the milestone L# and the printk marker string) and
extend the `MARKERS` array in `scripts/test_l_track.sh`.

## Why grep -F (fixed string)?

The marker is a literal byte sequence. We deliberately avoid regex
matching so that a future change to printk formatting (e.g. adding
a `[hamnix]` prefix to every line) does not silently break PASS
detection — the fixed string makes any drift loud.

## Related files

  * `linux_abi/exports.ad`        — symbol table the loader resolves against
  * `linux_abi/loader.ad`         — applies relocations + calls module_init
  * `scripts/test_l_track.sh`     — runs the regression
  * `scripts/build_linux_modules.sh` — rebuilds the .ko fixtures
  * `scripts/l_track_status.sh`   — pre-flight readiness report
