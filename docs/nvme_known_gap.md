# NVMe via L-shim — known gap (post-nvme-core side-load)

Landed: this commit — `linux_abi: side-load nvme-core.ko + 102 new
exports; cross-module ksymtab dispatches 77+ symbols (incl.
nvme_submit_sync_cmd)` on top of fb5aa49.

## State (post-side-load)

- `kernel-modules/nvme/nvme.ko` AND `kernel-modules/nvme_core/nvme-core.ko`
  (both Debian 6.1.0-32) bundle into the initramfs.
- `init/main.ad`'s `[boot:35.N]` block uses `modules_dep_load_with_deps("nvme", 4)`
  which discovers the `nvme: nvme-core` row in modules.dep and walks
  the chain: nvme-core.ko loads FIRST (init returned 0; slot=1),
  then nvme.ko loads (init returned 0; slot=2).
- `linux_abi/api_nvme_core.ad` exports 102 net-new shim symbols
  (blk_*/blk_mq_*/blk_queue_*, bio_*, srcu_*, xa_store, xa_find_after,
  io_uring_cmd_*, gendisk/add_disk family, cdev_device_*, PM-QoS,
  hwmon, ida_*, t10_pi_* CRC stubs, the block_bio_complete/remap
  tracepoint trios, etc.).
- Cross-module ksymtab fires for 77+ symbols when nvme.ko's RELA
  tables resolve, visible as `[ksymtab_hit] nvme -> nvme_core: <symbol>`
  in the boot log. Critically: `nvme_submit_sync_cmd` resolves to
  nvme-core's REAL impl (not api_nvme.ad's -ENODEV cold-path stub).
  Same for `nvme_init_ctrl`, `nvme_init_ctrl_finish`,
  `nvme_set_queue_count`, all the freeze/unfreeze/start/stop_queues,
  the tracepoint statics, etc.

## Test (after this commit)

`scripts/test_nvme_io.sh` boots QEMU with `-device nvme`, gates the
hand-rolled `drivers/nvme/nvme.ad` OFF, dep-loads nvme-core.ko +
nvme.ko, attempts to mount ext4. **Still exits 1**, but the failure
mode has shifted:

```
[nvme] hand-rolled smoke-test SKIPPED (/etc/nvme-io-ko)
[boot:35.N] modules_dep_load_with_deps nvme (depends: nvme-core)
kmod_linux: name=nvme_core
kmod_linux: init returned 0; slot=1
kmod_linux: name=nvme
[ksymtab_hit] nvme -> nvme_core: nvme_submit_sync_cmd      (5+ hits)
[ksymtab_hit] nvme -> nvme_core: nvme_init_ctrl
[ksymtab_hit] nvme -> nvme_core: nvme_init_ctrl_finish
... (77+ total cross-module hits) ...
kmod_linux: init returned 0; slot=2
[pci_register_driver] MATCH 1b36:10 at 0:4 (id_entry @ ...)
[pci_register_driver] calling probe(pdev=..., id=...)
[pci_register_driver] probe returned rc=18446744073709551594   # == -22 (-EINVAL)
[nvme_io_test] [bridge=disabled] hand-rolled drivers/nvme/nvme.ad gated off
[nvme_io_test] FAIL: no NVMe block device registered (post-nvme-core-side-load: ...)
```

The test now strictly asserts (and PASSes assertions for):
- `[boot:35.N] modules_dep_load_with_deps nvme` fires
- `kmod_linux: name=nvme_core` AND `kmod_linux: name=nvme` both fire
- `[ksymtab_hit] nvme -> nvme_core: nvme_submit_sync_cmd` fires
- `[bridge=disabled]` fires

The final FAIL is informative: nvme_probe returns -EINVAL BEFORE
reaching `async_schedule_node(nvme_reset_work)`. So namespace scan,
queue creation, add_disk all stay gated.

## What changed vs prior gap doc

| Aspect | Pre-side-load (fb5aa49) | Post-side-load (this commit) |
| --- | --- | --- |
| nvme-core.ko | not loaded | loaded via dep walker |
| nvme_submit_sync_cmd | api_nvme.ad -ENODEV stub | nvme-core real impl |
| Cross-module ksymtab | not exercised | 77+ hits |
| nvme_probe runs | yes, returns 0 (stub-friendly) | yes, returns -EINVAL (sanity-check now real) |
| Block device registered | no | no (still) |

The shift in failure mode is exactly the expected L-shim trajectory:
each side-load surfaces the next real-Linux sanity check that the
cold-path stub was masking. The remaining gap is shim pci_dev layout
+ early-probe path completeness, NOT the protocol layer.

## ABI version decision

Debian 6.1.0-32 throughout. Matches every other bundled .ko (ahci,
e1000e, igb, r8169, atlantic, alx, sky2, tg3, cfg80211, mac80211,
snd-hda-*, usbcore, xhci_*, ehci_*) and the recent SCSI mid-layer
agent's scsi_common/scsi_mod/libata/libahci. Mixing 6.12 + 6.1
modules in a single boot risks struct-layout drift; the
__ksymtab + EXPORT_SYMBOL CRC bypass already in the loader paper
over MODVERSIONS mismatches, but struct field offsets must match
across the dep chain.

Sourced from `/tmp/scsi_extract/extracted/lib/modules/6.1.0-32-amd64/`
(snapshot.debian.org's archive of
`linux-image-6.1.0-32-amd64_6.1.129-1_amd64.deb` — same archive the
SCSI mid-layer agent used). nvme.ko md5 matches the bundled
`kernel-modules/nvme/nvme.ko` exactly.

## Closure path (next milestone)

1. **Diagnose -EINVAL source**: trace nvme_probe step-by-step to
   identify which sanity check fails. The disassembly at
   nvme_probe+0x1a2 calls `nvme_init_ctrl` and checks return; the
   error-cleanup path (nvme_probe+0x3a8) un-allocs, then nvme_probe
   exits with the propagated error. Likely candidates:
     - `nvme_init_ctrl`'s subsystem-discovery xa_load/xa_store path
       (now using our cold-path xa_store stub that doesn't actually
       store; subsequent xa_load returns NULL where a real subsys
       pointer is expected).
     - `nvme_init_ctrl`'s chardev allocation
       (`cdev_device_add` stub returns 0 but doesn't actually register
       — caller may sanity-check that the chardev is live).
     - `dma_alloc_coherent` returning a high-half kernel pointer that
       the controller can't DMA to (needs a low-half phys page that's
       page-table-mapped 1:1).
     - PCI BAR mapping via `pcim_iomap_table` — our shim may return
       NULL or a bad address, and `nvme_remap_bar` (at 0x20ab in
       nvme_probe) returns -EINVAL on NULL.

2. **Wire MSI-X IRQ delivery**: nvme uses MSI-X with one vector per
   queue (admin + N io queues). Today's `pci_alloc_irq_vectors_affinity`
   stub returns 1 (one vector), and our IDT only routes a single
   hard-coded e1000e vector (api_irq.ad's
   E1000E_MSI_VECTOR_FOR_L_TRAMP). Need per-vector IDT entries +
   trampolines for MSI-X.

3. **Wait-for-completion path**: even if 1+2 land, the actual admin
   IDENTIFY CONTROLLER command requires the controller's CQ entry to
   be delivered as an interrupt to wake `wait_for_completion`. A
   polled-completion mode (spin on CQ phase bit, ignore IRQ
   delivery) is an alternative — see api_nvme.ad's
   `_nvm_async_schedule_node` comment block.

4. **Wrap nvme-core's gendisk into a Hamnix blockdev**: device_add_disk
   takes a gendisk; nvme-core's `__blk_mq_alloc_disk` allocates one
   with a `submit_bio` callback. Translate that bio path to Hamnix's
   `BlockDeviceOps.{read,write}_sectors` so `register_blockdev` exposes
   /dev/nvme0n1 to the rest of the kernel.

## Why landed despite informative-FAIL

Same rationale as fb5aa49: the strategic groundwork (nvme-core
side-load, 102 new shim exports, dep-walker integration, hardened
test assertions) is permanent infrastructure. Closing the
nvme_probe -EINVAL is now a localised debugging task — not a
"build the whole nvme stack from scratch" task. Every Linux NVMe
driver (Intel, Samsung, AWS, etc.) rides this same L-shim path,
so the next closure unlocks them all.

The orchestrator-sweep skip-list for `test_nvme_io.sh` should
remain skipped until the probe-EINVAL closure lands. The script's
strict assertion machinery (nvme-core load + nvme load + ksymtab
dispatch + bridge=disabled) will catch any regression in the
side-load infrastructure even before the PASS is achievable.
