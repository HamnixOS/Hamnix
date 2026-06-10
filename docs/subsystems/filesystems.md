# VFS & Filesystems

> **Source of truth:** `fs/` (all files), `kernel/block/blk.ad`
> **Last verified against source:** 2026-06-10

## Purpose

The VFS dispatch layer plus the concrete filesystem implementations.
VFS sits below the Plan-9 channel layer: `namec()` resolves a path to a
Chan, and for file-backed channels the Chan reads/writes through the VFS
and the appropriate `fs/*.ad` driver.

## Key files

| Path | Role |
|--|--|
| `fs/vfs.ad` | the VFS core: `vfs_init`, `vfs_open`, permission checks, initramfs + namespace-blob lookup, the per-task fd plumbing |
| `fs/vfs_mount.ad` | mount-table: `vfs_mount`, `vfs_umount`, `vfs_fs_kind`, path-prefix routing |
| `fs/ext4.ad` | ext4 read + write (extent leaves, htree dirs, offline grow); `fs/ext4_blob.S` is the baked test image |
| `fs/jbd2.ad` | ext4 journaling (jbd2) |
| `fs/fat.ad` / `fs/fat_mkfs.ad` | FAT12/16/32 read + mkfs |
| `fs/exfat.ad` | exFAT read + write (create, bitmap alloc, FAT chain) |
| `fs/ntfs.ad` | NTFS |
| `fs/btrfs.ad` | btrfs |
| `fs/iso9660.ad` | ISO9660 (CD) |
| `fs/squashfs.ad` | squashfs (the installer root); `fs/sqfsimg_blob.S` baked image |
| `fs/overlayfs.ad` | overlay/union mounts |
| `fs/tmpfs.ad` | in-RAM tmpfs |
| `fs/procfs.ad` | `/proc` synthetic files |
| `fs/cpio.ad` | initramfs (cpio) reader |
| `fs/pipe.ad` | anonymous pipes |
| `fs/socketpair.ad` / `fs/socket_state.ad` | `socketpair(2)` support (for the Linux ABI; not native sockets) |
| `fs/elf.ad` | ELF loader (kernel + user ELF32/64) |
| `fs/aes_xts.ad`, `fs/sha256.ad`, `fs/crc32c.ad` | crypto/checksum helpers for FS metadata + encryption |
| `fs/diskimg_blob.S` | baked disk-image test blob |
| `kernel/block/blk.ad` | the block layer + buffer cache feeding the FS drivers |

## Architecture & data structures

- **VFS dispatch** (`fs/vfs.ad`): `vfs_open(name)` is the entry; it routes
  by the mount table (`fs/vfs_mount.ad`) to the right FS driver, handles
  the cpio initramfs and namespace blobs (`ns_blob_*`), and applies
  permission checks (`_vfs_check_perm`, `vfs_perm_check_exec`) at the
  file-server boundary. Open files are recorded in the per-task fd table
  on `TaskStruct` (see [kernel-sched.md](kernel-sched.md)).
- **Mount table** (`fs/vfs_mount.ad`): `vfs_mount(path, fs_kind, strip, ...)`
  registers a path prefix → FS-kind mapping; `vfs_fs_kind(path)` and
  `vfs_fs_rel(path)` route a lookup to the owning FS and strip the prefix.
- **ext4** (`fs/ext4.ad`): `ext4_init(slot)` mounts a block-device slot;
  `ext4_read_inode`, extent-leaf walking, htree directory lookup
  (`ext4_dir_lookup_htree`), and a `metadata_csum`-aware offline grow with
  e2fsck-clean allocator bookkeeping. Journaling via `fs/jbd2.ad`.
- **Block layer** (`kernel/block/blk.ad`): the buffer cache; FS drivers
  read/write through it rather than touching device drivers directly.
  Block devices are named partition-aware (`sd0p1`, `nvme0n1p2`) and
  surfaced as the `#b` / `devblk` file server (see
  [plan9-namespace.md](plan9-namespace.md)).

## Entry points

- `vfs_init()` (`fs/vfs.ad:482`) — bring up VFS at boot.
- `vfs_open(name)` (`fs/vfs.ad:1233`) — the universal file open.
- `vfs_mount(path, fs_kind, strip, ...)` / `vfs_umount(slot)` (`fs/vfs_mount.ad`).
- `ext4_init(slot)` (`fs/ext4.ad:597`) / `ext4_is_mounted()` — ext4 mount.
- `_ext4_read_block` / `_ext4_write_block` / `_ext4_journal_write_block` — block I/O.

## Invariants & gotchas

- ext4 supports files up to ~512 MiB with multi-block extent leaves;
  larger or alternative inode layouts may not be handled.
- Grow operations must keep the allocator bookkeeping e2fsck-clean and
  `metadata_csum`-aware — a documented requirement of the offline-grow
  path.
- The installer root is **squashfs in RAM**; the installed root is
  **ext4 on NVMe**. Live media (CD/USB) historically could not read ext4
  off the medium (the cpio base shell covers that case) — see project
  memory and [../rootfs_partition.md](../rootfs_partition.md).
- One ext4 partition can serve **many** `#name` roots via the
  `.hamnix-roots` sentinel; don't break that multi-root invariant in
  mount reworks.

## Related docs

- [plan9-namespace.md](plan9-namespace.md) — channels + `devblk` that sit above VFS.
- [drivers.md](drivers.md) — the block device drivers (AHCI/NVMe/virtio) under the block layer.
- [../rootfs_partition.md](../rootfs_partition.md) — ext4 discovery + named roots.
