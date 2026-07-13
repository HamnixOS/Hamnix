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
    # install" environment, NOT an auto-wipe appliance. An installer that
    # erases whatever disk it finds the instant you attach one is a footgun —
    # so auto-install is OPT-IN, not the default.
    #
    # AUTO-INSTALL is gated on the /etc/installer-autorun marker, which is
    # planted ONLY by an unattended build (HAMNIX_INSTALLER_AUTORUN=1 —
    # scripts/build_initramfs.py). Two legitimate consumers: the keyboard-less
    # NUC appliance image (no one to type the command) and the CI install
    # regressions. A normal desktop install medium carries NO such marker and
    # ALWAYS boots the LIVE environment; there the user launches the installer
    # explicitly ("Install Hamnix" on the desktop, or `install` at a prompt),
    # which shows the disk menu and confirms the ERASE before touching a disk.
    #
    # try/except reacts ONLY to the LAST command, so each probe is the sole
    # statement in its own try. Even in autorun mode we still `install --probe`
    # so we never auto-install onto the boot medium itself (#410 self-clobber):
    # exit 0 = a distinct target exists, nonzero = only the boot medium (then
    # boot live even on an autorun medium — nothing safe to install onto).
    autorun = 1
    try {
        cat /etc/installer-autorun
    } except {
        autorun = 0
    }
    have_target = 0
    if $autorun > 0 {
        have_target = 1
        try {
            install --probe
        } except {
            have_target = 0
        }
    }
    if $have_target > 0 {
        echo 'rc.boot: installer-autorun + distinct target -- auto-running /etc/install_nvme.hamsh'
        source /etc/install_nvme.hamsh
    } else {
        echo 'rc.boot: booting LIVE environment (run `install` to install; auto-install is opt-in via /etc/installer-autorun)'
        # --- writable-in-RAM live root (#67) --------------------------
        # The LIVE native session's `/` is the read-only cpio embedded in
        # the kernel ELF (the kernel default namespace plants `/` -> `#r`;
        # this branch never `bind '#sysroot' /`, so no ext4 root shadows
        # it). A read-only `/` means `touch /root/x`, an `apt`-in-ns copy,
        # a config edit, all fail with EROFS — the live session cannot
        # write ANYWHERE outside the pre-bound `#t/tmp` + `#t/var` scratch.
        #
        # Make the whole live root appear WRITABLE, backed by RAM, using
        # the proven Plan-9 union-overlay primitive (NOT a Linux
        # overlayfs): union a writable tmpfs server (`#t`) MBEFORE the
        # read-only cpio root AND give it MCREATE (`bind -bc`). Now:
        #   * a READ of an existing cpio file (/bin/hamsh, /etc/passwd)
        #     misses the empty tmpfs member and falls THROUGH to the
        #     read-only cpio base — the toolset still resolves;
        #   * a CREATE anywhere (`touch /root/livetest`) is routed by
        #     resolve_path_create -> mnttab_create_target to the MCREATE
        #     tmpfs member (tmpfs auto-registers the `/root` synthetic
        #     root on demand), so it lands in RAM and reads back;
        #   * a truncating write to an existing cpio path
        #     (`echo hi > /etc/motd`) also takes the MCREATE route and
        #     shadows the cpio copy in tmpfs (copy-up-on-truncate).
        # Writes are RAM-only and volatile (lost on reboot) — exactly the
        # live-session contract. This is the SAME recipe the `enter linux`
        # apt/dpkg overlay uses (scripts/test_linux_apt_install_e2e.sh);
        # here it is applied to the ambient native root so every spawned
        # service (gettys, DE at runlevel 5, the interactive shell) that
        # inherits this boot namespace sees the writable tree. The `/tmp`,
        # `/var`, `/dev`, `/proc`, `/srv`, `/net` binds are longer-prefix
        # and keep their existing dedicated servers; the `/` union only
        # adds the writable member at the root union point.
        #
        # Scoped to the LIVE branch ONLY: the installed-to-disk boot binds
        # a real writable `#sysroot` ext4 at `/` (persistent), and the
        # `-kernel` dev path wants its cpio root untouched — neither takes
        # this branch.
        live_writable_ok = 1
        try {
            bind -bc '#t' /
        } except {
            live_writable_ok = 0
        }
        if $live_writable_ok > 0 {
            echo 'rc.boot: live root is WRITABLE in RAM (tmpfs union over cpio)'
        } else {
            echo 'rc.boot: WARNING could not make live root writable (read-only cpio)'
        }
        # LIVE Debian namespace (#410 Item 2): extract live-distro.ext4
        # out of the in-RAM /rootfs.sqfs into a RAM block device and
        # post its #distro named root (kernel does the work; see
        # drivers/block/loop.ad::loop_sqfs_live_root). Spawned DETACHED
        # so the desktop/heartbeat boot timing is unaffected — the
        # `linux`/`debian` ns recipes captured by rc.boot.full bind
        # '#distro' at ENTER time, so `enter linux { ... }` works as
        # soon as the kernel prints "[live-root] DONE". `ns { }` is an
        # empty overlay: the tool inherits this boot namespace (it only
        # needs /dev/loop/ctl).
        livens = ns {
        }
        livesvc = spawn detached livens {
            live_distro_up
        }
        source /etc/rc.boot.full
        # Normal-distro identity: the LIVE session logs in as the default
        # REGULAR user `live` (uid 1001), NOT the hostowner. All the
        # privileged boot setup above ran as hostowner (uid 1); now that
        # the desktop + services are up we DROP this interactive console
        # to `live`. Admin work is an explicit `newshell hostowner`
        # (password) elevation, exactly like sudo on a normal distro.
        # setuid here is a privilege-DROP (uid 1 -> 1001), always allowed.
        # After this returns to hamsh main(), _set_home_from_passwd() sets
        # HOME=/home/live and _load_per_user_namespace() sources the
        # regular-user recipe for uid 1001. The -kernel test path and the
        # installed-system boot take the OTHER rc.boot branches and stay
        # hostowner, so this drop is scoped to the live image only.
        echo 'rc.boot: live session -- dropping console to regular user live (uid 1001)'
        setuid 1001
    }
} else {
    # --- normal boot: mount the sysroot subtree at / ----------------
    # Try to graft the partition's `sysroot` subtree onto `/`. On
    # success the FULL rc and the ~110 admin tools resolve off ext4; on
    # failure we fall through to the read-only cpio tools embedded in
    # the kernel. That cpio fallback is BENIGN on the `-kernel`
    # developer test path (no rootfs partition was ever attached — the
    # cpio IS the intended root), but it is a SILENT DISASTER on a real
    # INSTALLED system: the operator would unknowingly run stale in-RAM
    # tools and every file/edit/update would appear to vanish with no
    # explanation.
    sysroot_ok = 1
    try {
        bind '#sysroot' /
    } except {
        sysroot_ok = 0
    }
    if $sysroot_ok > 0 {
        echo 'rc.boot: sysroot partition mounted at /'
    } else {
        # The bind failed. Decide loud-vs-quiet by the *sysroot device*
        # signal: did the box actually have a real root DISK? A real
        # block disk is present ONLY on a genuine installed/HW system;
        # the `-kernel` developer test attaches NO block device at all,
        # so /dev/blk is empty there and the cpio IS the intended root.
        # We probe with the proven `try { cat … } except` exit-code
        # idiom (NOT command substitution — `{ … }` capture deadlocks
        # this early in the PID-1 bootstrap). `cat <disk>/size` reads a
        # disk's capacity node: it SUCCEEDS only if that whole-disk node
        # exists, and FAILS (lands in except) when no such device is
        # registered. We try each whole-disk name the kernel/installer
        # can use (virtio vda/vdb, AHCI/USB sd0, NVMe nvme0n1). Output is
        # Each probe follows the SAME shape the installer-medium check
        # above uses: the `cat` is the SOLE statement in its `try` (so
        # try/except keys off ITS status), and the flag is set to 1
        # up-front and cleared to 0 in the `except` when the device is
        # absent. `installed` is the OR (sum) of the per-disk flags; it
        # is > 0 only when at least one real disk exists.
        vda_ok = 1
        try {
            cat /dev/blk/vda/size
        } except {
            vda_ok = 0
        }
        nvme_ok = 1
        try {
            cat /dev/blk/nvme0n1/size
        } except {
            nvme_ok = 0
        }
        sd0_ok = 1
        try {
            cat /dev/blk/sd0/size
        } except {
            sd0_ok = 0
        }
        vdb_ok = 1
        try {
            cat /dev/blk/vdb/size
        } except {
            vdb_ok = 0
        }
        installed = $vda_ok + $nvme_ok + $sd0_ok + $vdb_ok
        if $installed > 0 {
            # INSTALLED / real-HW system whose root failed to bind. Cry
            # LOUD: the operator is now on throwaway in-RAM tools and
            # NOTHING they do will persist. A quiet one-liner here is
            # exactly the silent-failure class this guard exists to kill.
            echo '################################################################'
            echo 'rc.boot: ******* ROOT FILESYSTEM FAILED TO MOUNT *******'
            echo 'rc.boot: a real root disk is present but its #sysroot subtree'
            echo 'rc.boot:   could NOT be bound at / (corrupt or unenumerated'
            echo 'rc.boot:   ext4 root).'
            echo 'rc.boot: You are now running the FALLBACK in-RAM (cpio) tools.'
            echo 'rc.boot: *** CHANGES WILL NOT PERSIST. Your installed files,'
            echo 'rc.boot: *** edits and updates are NOT visible in this shell.'
            echo 'rc.boot: Do NOT treat this as a normal boot. Investigate the'
            echo 'rc.boot:   root disk before making any changes.'
            echo '################################################################'
        } else {
            # Genuine live/dev path: no root disk present at all, so the
            # cpio IS the intended root. Stay quiet — don't cry wolf.
            echo 'rc.boot: no sysroot partition (#sysroot absent) -- cpio fallback (live/dev image)'
        }
    }
    source /etc/rc.boot.full
}
