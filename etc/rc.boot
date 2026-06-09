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
#   bind '#s' /srv      — name-server directory
#   bind '#p' /proc     — per-task introspection
#   bind '#/' /n        — conventional mount-point parent
#   bind '#c' /dev      — device directory server (cons/null/zero/blk)
#   bind '#b' /dev/blk  — block-device server (nvme0n1, sd0, vda, ...)
#   bind '#I' /net      — IP device server (tcp/udp/icmp, clone, conns)
# The '#b' bind is a LONGER prefix than '#c', so /dev/blk/<name> routes
# to the block server while /dev/<other> stays with the '#c' dev server
# (longest-prefix match). This is what makes `ls /dev`, `ls /dev/blk`,
# and `lsblk` enumerate devices through the namespace instead of a
# kernel literal-path match. '#I' is the Plan 9 IP stack: a `/net/tcp/clone`
# open is rewritten to `#I/tcp/clone`, so the whole networking surface is
# namespace-resolved (no literal /net match in the kernel).
bind '#s' /srv
bind '#p' /proc
bind '#/' /n
bind '#c' /dev
bind '#b' /dev/blk
bind '#I' /net
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
# --- installer medium: AUTO-RUN the in-RAM NVMe installer -----------
# The in-RAM-squashfs install medium carries /etc/installer-medium in the
# cpio (planted ONLY by scripts/build_installer_img.sh). On that medium the
# whole boot exists to run /etc/install_nvme.hamsh, and the real NUC target
# has NO working keyboard — so the installer MUST start itself; there is no
# one to type it. `cat` exits nonzero when the marker is absent (every
# normal/installed boot), so try/except falls straight through to the
# regular sysroot hand-off. When the marker IS present we source the
# installer and STOP — we never mount a sysroot partition or run the full
# rc, because the installer owns the box and writes the NVMe target raw.
# hamsh try/except reacts ONLY to the LAST command in the try block, so the
# existence probe MUST be the sole command in its own try. We set a flag and
# branch with `if` — folding the probe and the action into one try block would
# make the INSTALLED system (marker absent, `cat` fails) still run the action
# and re-partition its own boot disk (a self-wipe loop).
installer_medium = 1
try {
    cat /etc/installer-medium
} except {
    installer_medium = 0
}
if $installer_medium > 0 {
    # First-class LIVE image: the install medium is a "try before you
    # install" environment, not an auto-wipe appliance. Decide between
    # auto-installing and booting the live desktop by asking the installer
    # whether a target distinct from the boot medium exists.
    #   `install --probe` exits 0 when a real install target is present
    #   (e.g. the keyboard-less NUC's blank NVMe) and nonzero when the only
    #   disk IS the boot medium (e.g. a VM where the image is attached as an
    #   ordinary virtio disk). In the latter case auto-installing would
    #   erase the running installer (#410 self-clobber), so we boot live.
    # try/except reacts ONLY to the LAST command, so the probe is its sole
    # statement; a nonzero exit lands in except and clears have_target.
    have_target = 1
    try {
        install --probe
    } except {
        have_target = 0
    }
    if $have_target > 0 {
        echo 'rc.boot: install target present -- auto-running /etc/install_nvme.hamsh'
        source /etc/install_nvme.hamsh
    } else {
        echo 'rc.boot: only the boot medium present -- booting LIVE environment'
        source /etc/rc.boot.full
    }
} else {
    # --- normal boot: mount the sysroot subtree at / ----------------
    try {
        bind '#sysroot' /
        echo 'rc.boot: sysroot partition mounted at /'
    } except {
        echo 'rc.boot: no sysroot partition (#sysroot absent) -- cpio fallback'
    }
    source /etc/rc.boot.full
}
