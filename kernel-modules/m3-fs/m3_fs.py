# Pynux M3.3 (full): a real ramfs-class filesystem (pynuxfs).
#
# Mounts, supports file create / write / read / mkdir / unlink / rmdir.
# Uses the kernel's libfs helpers for everything the kernel exports
# (simple_*, generic_file_*, noop_*, simple_lookup, simple_dir_operations)
# and supplies its own ramfs_* equivalents for the few that aren't
# (mknod/create/mkdir + dget-replacement via lockref_get).
#
# Struct layouts verified for linux-6.12.48 by /tmp/probe (sizes:
# file_system_type=72, fs_context_operations=48, super_operations=208,
# inode_operations=256, file_operations=264,
# address_space_operations=160, address_space=192,
# super_block=1280, inode=592, dentry=192).

# -------- externs ----------------------------------------------------------
extern def register_filesystem(fs: Ptr[uint8]) -> int32
extern def unregister_filesystem(fs: Ptr[uint8]) -> int32
extern def get_tree_nodev(fc: Ptr[uint8], fill_super: Ptr[uint8]) -> int32
extern def kill_litter_super(sb: Ptr[uint8])
extern def kzalloc(size: uint64, flags: uint32) -> Ptr[uint8]
extern def kfree(p: Ptr[uint8])
extern def new_inode(sb: Ptr[uint8]) -> Ptr[uint8]
extern def get_next_ino() -> uint32
extern def inc_nlink(inode: Ptr[uint8])
extern def d_make_root(inode: Ptr[uint8]) -> Ptr[uint8]
extern def d_instantiate(dentry: Ptr[uint8], inode: Ptr[uint8])
extern def lockref_get(lr: Ptr[uint8])
extern def simple_inode_init_ts(inode: Ptr[uint8])
extern def memcpy(dst: Ptr[uint8], src: Ptr[uint8], n: uint64) -> Ptr[uint8]
extern def _printk(fmt: str, val: int32) -> int32

# Most "callbacks" we hook are kernel symbols whose addresses we take.
# Declaring them as extern def works because the codegen emits
# `leaq name(%rip), %rax` for any extern name used as an r-value — even
# if the symbol is actually a global variable rather than a function.
extern def simple_statfs() -> int32
extern def generic_delete_inode() -> int32
extern def simple_lookup() -> Ptr[uint8]
extern def simple_link() -> int32
extern def simple_unlink() -> int32
extern def simple_rmdir() -> int32
extern def simple_rename() -> int32
extern def simple_setattr() -> int32
extern def simple_getattr() -> int32
extern def simple_dir_operations() -> int32          # extern global

extern def generic_file_read_iter() -> int32
extern def generic_file_write_iter() -> int32
extern def generic_file_llseek() -> int32
extern def generic_file_mmap() -> int32
extern def noop_fsync() -> int32
extern def filemap_splice_read() -> int32
extern def iter_file_splice_write() -> int32

# ram_aops is exported by libfs and already wires up
# simple_read_folio + simple_write_begin + simple_write_end + noop_dirty_folio.
# We just point inode->i_mapping->a_ops at it.
extern def ram_aops() -> int32     # extern global address_space_operations

# -------- struct layouts ---------------------------------------------------

# struct file_system_type (72 bytes)
class FileSystemType:
    name: Ptr[char]
    fs_flags: int32
    pad_after_fs_flags: int32
    init_fs_context: Ptr[uint8]
    parameters: Ptr[uint8]
    pad_32: Ptr[uint8]
    kill_sb: Ptr[uint8]
    owner: Ptr[uint8]
    fst_next: Ptr[uint8]
    pad_64: Ptr[uint8]

# struct fs_context_operations (48 bytes — 6 slots)
class FsContextOps:
    free: Ptr[uint8]
    dup: Ptr[uint8]
    parse_param: Ptr[uint8]
    parse_monolithic: Ptr[uint8]
    get_tree: Ptr[uint8]
    reconfigure: Ptr[uint8]

# struct super_operations (208 bytes — only fill drop_inode@40 and statfs@104)
class SuperOps:
    opaque_pre: Array[40, uint8]
    drop_inode: Ptr[uint8]
    opaque_mid: Array[56, uint8]
    statfs: Ptr[uint8]
    opaque_post: Array[96, uint8]

# struct inode_operations (256 bytes — populate lookup, create, link,
# unlink, mkdir, rmdir, mknod, rename, setattr, getattr).
class InodeOps:
    lookup: Ptr[uint8]              # 0
    pad_after_lookup: Array[32, uint8]
    create: Ptr[uint8]              # 40
    link: Ptr[uint8]                # 48
    unlink: Ptr[uint8]              # 56
    symlink: Ptr[uint8]             # 64
    mkdir: Ptr[uint8]               # 72
    rmdir: Ptr[uint8]               # 80
    mknod: Ptr[uint8]               # 88
    rename: Ptr[uint8]              # 96
    setattr: Ptr[uint8]             # 104
    getattr: Ptr[uint8]             # 112
    pad_end: Array[136, uint8]      # 120..256

# struct file_operations (264 bytes)
class FileOps:
    owner: Ptr[uint8]               # 0
    fop_flags: Array[8, uint8]      # 8..16
    llseek: Ptr[uint8]              # 16
    read: Ptr[uint8]                # 24
    write: Ptr[uint8]               # 32
    read_iter: Ptr[uint8]           # 40
    write_iter: Ptr[uint8]          # 48
    pad1: Array[40, uint8]          # 56..96
    mmap: Ptr[uint8]                # 96
    pad2: Array[24, uint8]          # 104..128
    fsync: Ptr[uint8]               # 128
    pad3: Array[16, uint8]          # 136..152
    get_unmapped_area: Ptr[uint8]   # 152
    pad4: Array[16, uint8]          # 160..176
    splice_write: Ptr[uint8]        # 176
    splice_read: Ptr[uint8]         # 184
    pad_end: Array[72, uint8]       # 192..264

# -------- globals ---------------------------------------------------------

pynux_fs_type: FileSystemType
pynux_ctx_ops: FsContextOps
pynux_sb_ops: SuperOps
pynux_dir_iops: InodeOps
pynux_file_iops: InodeOps
pynux_file_fops: FileOps

# -------- offsets in kernel structs (verified via probes) -----------------
SB_BLOCKSIZE_OFF:  int32 = 24
SB_MAXBYTES_OFF:   int32 = 32
SB_OP_OFF:         int32 = 48
SB_MAGIC_OFF:      int32 = 96
SB_ROOT_OFF:       int32 = 104
SB_TIME_GRAN_OFF:  int32 = 880

INODE_MODE_OFF:    int32 = 0
INODE_OP_OFF:      int32 = 32
INODE_SB_OFF:      int32 = 40
INODE_MAPPING_OFF: int32 = 48
INODE_INO_OFF:     int32 = 64
INODE_FOP_OFF:     int32 = 336

AS_AOPS_OFF:       int32 = 104
AS_FLAGS_OFF:      int32 = 112
AS_GFP_OFF:        int32 = 64

DENTRY_LOCKREF_OFF: int32 = 128

# mode bits + magic
S_IFDIR:           int32 = 0x4000
S_IFREG:           int32 = 0x8000
S_IFMT:            int32 = 0xF000
DIR_MODE:          int32 = 16877        # S_IFDIR | 0755
FILE_MODE_MASK:    int32 = 0x1FF        # 0777 — caller-supplied mode bits

GFP_KERNEL:        uint32 = 0xcc0
AS_UNEVICTABLE_BIT: int64 = 8           # 1 << 3
PYNUXFS_MAGIC:     uint64 = 0x50594E55

ENOSPC_NEG:        int32 = -28

# -------- helpers ---------------------------------------------------------

def pynux_dget(dentry: Ptr[uint8]):
    # dget is a static inline; substitute lockref_get on &dentry->d_lockref.
    lockref_get(dentry + DENTRY_LOCKREF_OFF)


def pynux_get_inode(sb: Ptr[uint8], dir: Ptr[uint8],
                    mode: int32, dev: int32) -> Ptr[uint8]:
    inode: Ptr[uint8] = new_inode(sb)
    if inode == 0:
        return 0

    # i_ino = get_next_ino()
    ino: uint32 = get_next_ino()
    memcpy(inode + INODE_INO_OFF, &ino, 8)
    # i_mode = mode (umode_t = u16)
    mode_val: int32 = mode
    memcpy(inode + INODE_MODE_OFF, &mode_val, 2)
    simple_inode_init_ts(inode)

    fmt: int32 = mode & S_IFMT
    if fmt == S_IFDIR:
        diops_ptr: Ptr[uint8] = &pynux_dir_iops
        memcpy(inode + INODE_OP_OFF, &diops_ptr, 8)
        dfops_ptr: Ptr[uint8] = simple_dir_operations
        memcpy(inode + INODE_FOP_OFF, &dfops_ptr, 8)
        # Directories start with nlink = 2 ("." entry).
        inc_nlink(inode)
    if fmt == S_IFREG:
        fiops_ptr: Ptr[uint8] = &pynux_file_iops
        memcpy(inode + INODE_OP_OFF, &fiops_ptr, 8)
        ffops_ptr: Ptr[uint8] = &pynux_file_fops
        memcpy(inode + INODE_FOP_OFF, &ffops_ptr, 8)
        # Wire the file's page-cache mapping to ram_aops (libfs export).
        mapping: Ptr[uint8] = 0
        memcpy(&mapping, inode + INODE_MAPPING_OFF, 8)
        aops_ptr: Ptr[uint8] = ram_aops
        memcpy(mapping + AS_AOPS_OFF, &aops_ptr, 8)
        # mapping->flags |= AS_UNEVICTABLE
        flags_val: int64 = 0
        memcpy(&flags_val, mapping + AS_FLAGS_OFF, 8)
        flags_val = flags_val | AS_UNEVICTABLE_BIT
        memcpy(mapping + AS_FLAGS_OFF, &flags_val, 8)
        # mapping->gfp_mask = GFP_KERNEL
        gfp_val: uint32 = GFP_KERNEL
        memcpy(mapping + AS_GFP_OFF, &gfp_val, 4)

    return inode


def pynux_mknod(idmap: Ptr[uint8], dir: Ptr[uint8],
                dentry: Ptr[uint8], mode: int32, dev: int32) -> int32:
    # sb = dir->i_sb
    sb: Ptr[uint8] = 0
    memcpy(&sb, dir + INODE_SB_OFF, 8)
    inode: Ptr[uint8] = pynux_get_inode(sb, dir, mode, dev)
    if inode == 0:
        return ENOSPC_NEG
    d_instantiate(dentry, inode)
    pynux_dget(dentry)
    return 0


def pynux_create(idmap: Ptr[uint8], dir: Ptr[uint8],
                 dentry: Ptr[uint8], mode: int32, excl: int32) -> int32:
    return pynux_mknod(idmap, dir, dentry, mode | S_IFREG, 0)


def pynux_mkdir_op(idmap: Ptr[uint8], dir: Ptr[uint8],
                   dentry: Ptr[uint8], mode: int32) -> int32:
    rc: int32 = pynux_mknod(idmap, dir, dentry, mode | S_IFDIR, 0)
    if rc == 0:
        inc_nlink(dir)
    return rc


# -------- fill_super / fs_context / module init --------------------------

def pynux_fill_super(sb: Ptr[uint8], fc: Ptr[uint8]) -> int32:
    maxbytes: int64 = 0x7fffffffffffffff
    memcpy(sb + SB_MAXBYTES_OFF, &maxbytes, 8)
    bs: int32 = 4096
    memcpy(sb + SB_BLOCKSIZE_OFF, &bs, 4)
    magic: int64 = PYNUXFS_MAGIC
    memcpy(sb + SB_MAGIC_OFF, &magic, 8)
    gran: int32 = 1
    memcpy(sb + SB_TIME_GRAN_OFF, &gran, 4)
    sop_ptr: Ptr[uint8] = &pynux_sb_ops
    memcpy(sb + SB_OP_OFF, &sop_ptr, 8)

    root: Ptr[uint8] = pynux_get_inode(sb, 0, DIR_MODE, 0)
    if root == 0:
        return -12  # -ENOMEM
    dentry: Ptr[uint8] = d_make_root(root)
    memcpy(sb + SB_ROOT_OFF, &dentry, 8)
    return 0


def pynux_get_tree(fc: Ptr[uint8]) -> int32:
    return get_tree_nodev(fc, pynux_fill_super)


def pynux_init_fs_context(fc: Ptr[uint8]) -> int32:
    ops_ptr: Ptr[uint8] = &pynux_ctx_ops
    memcpy(fc, &ops_ptr, 8)
    return 0


def pynux_kill_sb(sb: Ptr[uint8]):
    kill_litter_super(sb)


def init_module() -> int32:
    # Directory inode operations: real callbacks for mutation, libfs helpers
    # for the rest.
    pynux_dir_iops.lookup = simple_lookup
    pynux_dir_iops.create = pynux_create
    pynux_dir_iops.link = simple_link
    pynux_dir_iops.unlink = simple_unlink
    pynux_dir_iops.mkdir = pynux_mkdir_op
    pynux_dir_iops.rmdir = simple_rmdir
    pynux_dir_iops.mknod = pynux_mknod
    pynux_dir_iops.rename = simple_rename

    # File inode operations: just attribute access.
    pynux_file_iops.setattr = simple_setattr
    pynux_file_iops.getattr = simple_getattr

    # File operations: route everything through libfs/page-cache generics.
    pynux_file_fops.llseek = generic_file_llseek
    pynux_file_fops.read_iter = generic_file_read_iter
    pynux_file_fops.write_iter = generic_file_write_iter
    pynux_file_fops.mmap = generic_file_mmap
    pynux_file_fops.fsync = noop_fsync
    pynux_file_fops.splice_read = filemap_splice_read
    pynux_file_fops.splice_write = iter_file_splice_write

    # Address-space ops come from libfs's ram_aops directly — no
    # populating-from-Pynux needed.

    # Super ops.
    pynux_sb_ops.statfs = simple_statfs
    pynux_sb_ops.drop_inode = generic_delete_inode

    # fs_context ops.
    pynux_ctx_ops.get_tree = pynux_get_tree

    # file_system_type.
    pynux_fs_type.name = "pynuxfs"
    pynux_fs_type.init_fs_context = pynux_init_fs_context
    pynux_fs_type.kill_sb = pynux_kill_sb

    register_filesystem(&pynux_fs_type)
    _printk("[M3-FS] registered\n", 0)
    return 0


def cleanup_module():
    unregister_filesystem(&pynux_fs_type)
    _printk("[M3-FS] unregistered\n", 0)
