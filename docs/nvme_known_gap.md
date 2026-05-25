# NVMe via L-shim — known gap (no real I/O end-to-end)

Landed: 6f63141 — `nvme.ko: exercise test — mount ext4, read+write file via
Linux shim path (no bridge)` (2026-05-25).

## State

- `kernel-modules/nvme/nvme.ko` loads cleanly via the L-shim.
- `linux_abi/api_nvme.ad` has 89 stubs; ~36 `nvme_*` core symbols return
  cold-path defaults (e.g. `nvme_submit_sync_cmd` returns `-ENODEV`).
- These are sized to let `init_module` / `nvme_probe` return success
  cleanly — `scripts/test_nvme_ko.sh` (load-only) passes.
- They are NOT sized to let real I/O flow: namespace scan never runs,
  no `nvme0n1` block device registers.

## Test

`scripts/test_nvme_io.sh` boots QEMU with `-device nvme`, gates the
hand-rolled `drivers/nvme/nvme.ad` OFF, loads `nvme.ko`, attempts to
mount ext4. **Exits 1 by design** with:

```
[nvme] hand-rolled smoke-test SKIPPED (/etc/nvme-io-ko)
[boot:35.N] kmod_linux_load /lib/modules/6.12/nvme.ko
[nvme.ko] kmod_linux_load OK
[nvme_io_test] [bridge=disabled] hand-rolled drivers/nvme/nvme.ad gated off
[nvme_io_test] FAIL: no NVMe block device registered (nvme.ko shim
 does not register block devices; nvme-core.ko stubs return -ENODEV
 from submit_sync_cmd, so namespace scan + blk_mq_alloc_disk never run)
```

The `[bridge=disabled]` marker fires, confirming the failure is genuine —
not masked by fall-back to the hand-rolled driver.

## Closure path

Side-load Linux's `nvme-core.ko` (and `nvme.ko` proper) so the real
`nvme_submit_sync_cmd` replaces the shim stub. Parallel to what the
SCSI mid-layer agent is doing for `scsi_mod` / `libata`. Estimated
8-20h focused agent work, payoff reusable for any NVMe device.

## Why landed despite informative-FAIL

The scaffolding (image builder, exercise function, marker gating,
`[bridge=disabled]` ground-truth marker) is real value. When the
`nvme-core.ko` side-load lands, `test_nvme_io.sh` flips to PASS with
zero scaffolding changes. The orchestrator should skip
`test_nvme_io.sh` in sweeps until that lands.
