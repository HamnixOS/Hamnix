# apt-get install — remaining blocker: NX exec-fault (post dpkg-deb-unpack fix)

Status: 2026-06-27. The dpkg-deb UNPACK pipeline is FIXED (see below);
`apt-get install hamhello` now has a SEPARATE, deeper blocker: an NX
execution fault inside libapt-pkg's resolver/cache code.

## What was fixed (this session)

`dpkg -i hamhello.deb` and `dpkg --force-all -P hamhello` now work end to
end and reach "Setting up hamhello (1.0)". Root cause was a cpio embed
spelling skew: `scripts/build_initramfs.py`'s `REAL_DEBIAN_FILES` listed
the helper binaries dpkg-deb forks (tar/gzip/rm/cp/mkdir/chmod/ln/...) as
`bin/tar`, `bin/gzip`, ... but `scripts/stage_host_dpkg_rootfs.sh` stages
the real binaries ONLY under `usr/bin/` (its `bin/` holds just sh/dash
symlinks). So `(minbase_rootfs / "bin/tar").is_file()` was False and the
embed loop SILENTLY SKIPPED every one — neither `/usr/bin/tar` nor
`/bin/tar` (Debian) ever landed in the cpio distro slice. dpkg-deb's
`execvp("tar")` PATH walk then missed `/usr/bin/tar` and fell through to
the NATIVE Adder `/bin/tar` (user/tar.ad) baked into the global cpio,
which rejects GNU tar flags with "tar: unknown flag" -> dpkg-deb exits 1
mid-unpack, BEFORE "Unpacking". Fix: spell them `usr/bin/<x>`; the
existing USRMERGE_ALIASES expansion also plants `/bin/<x>` from the same
bytes, shadowing the native tar inside the `#distro`-bound namespace.
Guard added to scripts/test_linux_apt_install_e2e.sh (check_absent
"tar: unknown flag" / "command not found: /usr/bin/tar").

## The remaining apt-get install blocker (NOT YET FIXED)

`apt-get update` SUCCEEDS (Release + Packages fetched from
file:///opt/localrepo, "Reading package lists... Done"). The combined
`apt-get update && apt-get install -y hamhello` leg then crashes:

    [pf] NX exec-fault on user page va=0x0000000051c0f000 -> SIGSEGV
    task: pid 33 exited (code=139)
    task: pid 34 exited (code=139)

(the many code=130 sibling exits are apt's method workers torn down after
the main process crashed).

### Triage verdict

- Fault VA 0x51c0f000 is in the LOW mmap arena (~0x40000000-0x52000000)
  where libapt's shared libs + mmap'd package cache land — NOT the ELF
  load bias (~0x11-0x13xxxxxxxx).
- The page-fault handler at arch/x86/kernel/trap_diag.ad:301-330 detects
  the instruction-fetch-on-NX (P=1,U=1,I/D=1) and calls
  `vma_resolve_exec_perm_fault()` (the stale-NX-leaf recovery for ld.so's
  reserve(PROT_READ,NX)+MAP_FIXED-overlay(PROT_EXEC) idiom). For this
  fault that recovery returned NOT 1 -> NO covering VMA granted exec at
  the fault VA, so it fell through to SIGSEGV.
- mprotect is NOT the culprit: fs/elf.ad vm_protect_range() correctly
  clears PT_FLAG_NX (bit 63) on PROT_EXEC and invlpg's the leaf.
- Prime suspect (matches the in-code comments at mm/vma.ad:2829-2841,
  2915 and prior fixes 54ab83f0 / 371d61a9 / 3e4b7acf): OVERLAPPING /
  stacked MAP_FIXED alias VMA nodes corrupt the interval-tree point
  query (_vma_tree_find descends the BST on `start` and can return 0 for
  an address two siblings both cover), so the exec-fault resolver finds
  "no covering VMA" for a page an EXEC VMA legitimately covers, and the
  eager PTE re-stamp leaves NX on an executable page. dpkg -i does NOT
  trip it; apt-get install's heavier ld.so MAP_FIXED overlay sequence
  (more DSOs: libapt-pkg, libapt-private, libstdc++, the resolver) does.
  `_vma_drop_overlapping_aliases()` (mm/vma.ad:2829) is the existing
  partial mitigation; it is NOT fully covering apt's case.

### Next step (separate, substantial VMA track)

Reproduce with the apt-get install leg, enable vma_dbg_dump_cover at the
NX fault, and confirm whether an EXEC-granting VMA exists at 0x51c0f000
that the interval-tree point query fails to return (interval-tree
corruption) vs. a genuine hole the overlay never covered. Fix the
interval tree to return ANY covering node for a point query (or dedup the
stacked aliases at insert), so vma_resolve_exec_perm_fault can clear the
stale NX. This is in mm/vma.ad, not in linux_abi or the cpio staging.
