# /etc/rc.boot — the tiny cpio-resident BOOTSTRAP rc, interpreted by
# hamsh running as PID 1.
#
# The kernel ELF-loads /init (a 2-line shim that execs
# `/bin/hamsh /etc/rc.boot`). At that instant the only filesystem the
# shell can see is the read-only cpio embedded in the kernel ELF, so
# THIS file is what hamsh sources first. Its sole job is to bring the
# sysroot partition online and hand off to the FULL rc that lives on
# that partition (sysroot/etc/rc.boot, staged from etc/rc.boot.full).
#
# DESIGN (docs/rootfs_partition.md, multi-root layout): the ext4 rootfs
# partition's top level is a set of named subtree roots declared in a
# `.hamnix-roots` sentinel — `sysroot sysroot`, `distro distro`, plus a
# per-user `<username> <username>` line for each non-hostowner user.
# The kernel parses the sentinel at boot and posts each subtree as a
# named file server (`#sysroot`, `#distro`, `#<username>`). This rc
# binds the `sysroot` subtree at `/`, so the native admin filesystem
# (/bin with the ~110 Adder tools, /etc, /usr, ...) resolves onto the
# partition.
#
# RESILIENCE: the `-kernel` developer test path attaches NO rootfs
# partition, so `#sysroot` does not exist there. `bind '#sysroot' /`
# fails (nonzero) in that case; we detect it and FALL BACK to the cpio
# root, which in the non-lean cpio those tests use already contains the
# full toolset and the full rc inline. The interactive shell still gets
# commands.
#
# Syntax notes: '#' starts a comment; device-letter names like '#s'
# MUST be single-quoted; '[' ']' ':' are tokens. `bind SRC DST` is
# source-first.

echo 'rc.boot: bootstrap rc starting'

# --- device binds (always applied, cpio or partition) ---------------
# The kernel exposes raw devices under '#X' letter aliases. These three
# binds give them their conventional Plan 9 path names in the ambient
# namespace; every command hamsh later spawns inherits this table.
#   bind '#s' /srv   — name-server directory
#   bind '#p' /proc  — per-task introspection
#   bind '#/' /n     — conventional mount-point parent
bind '#s' /srv
bind '#p' /proc
bind '#/' /n
echo 'rc.boot: device binds applied'

# --- mount the sysroot subtree at / ---------------------------------
# `bind '#sysroot' /` grafts the partition's `sysroot` subtree onto the
# root lookup name. _freeze_named_source (kernel) rewrites '#sysroot' to
# a stable '#by-id/<partuuid>/sysroot' alias at bind time, baking the
# sentinel relpath in so /bin/ls resolves to /ext/sysroot/bin/ls on the
# partition (not /ext/bin/ls). After this bind succeeds, /etc/rc.boot
# resolves to the partition's full rc.
#
# If the bind fails (no rootfs partition — the `-kernel` test path),
# bind returns nonzero; `try`/`except` swallows the error noise so the
# boot continues. EITHER WAY we then `source /etc/rc.boot.full`:
#   - bind succeeded: /etc/rc.boot.full resolves to the PARTITION copy
#     (sysroot/etc/rc.boot.full), bringing the native admin filesystem
#     online.
#   - bind failed: /etc/rc.boot.full resolves to the CPIO copy, which
#     build_initramfs.py embeds in the non-lean cpio for exactly this
#     fallback. The non-lean cpio those `-kernel` tests use already
#     carries the full toolset, so the shell still has commands.
# The `source` runs in THIS hamsh process (PID 1), so every bind/`=` in
# the full rc persists into the interactive shell's namespace.
try {
    bind '#sysroot' /
    echo 'rc.boot: sysroot partition mounted at /'
} except {
    echo 'rc.boot: no sysroot partition (#sysroot absent) -- cpio fallback'
}
source /etc/rc.boot.full
