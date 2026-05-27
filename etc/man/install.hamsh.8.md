# install.hamsh - the Hamnix installer

## NAME

install.hamsh - install Hamnix from the live ISO to a target disk

## SYNOPSIS

    /etc/install.hamsh

## DESCRIPTION

`install.hamsh` is the on-disk installer: a hamsh script (not a
binary) that drives the live ISO's installation flow. It runs
as hostowner after a password prompt, and walks the steps:

  1. partition the target disk (`hamnix_partition`)
  2. format the ESP and rootfs partitions (`mkfs_fat`, `mkfs_ext4`)
  3. copy every entry from `/etc/install/rootfs.manifest` onto
     the target ext4 partition via `install_rootfs_from_manifest`
  4. install the bootloader stub on the ESP
  5. configure first-boot defaults (`/etc/hostname`, hostowner)
  6. reboot into the installed system

The manifest at `/etc/install/rootfs.manifest` is generated at
ISO-build time by `scripts/gen_install_manifest.py`; each line is
`<target-path> <source-path>`. The installer walks this table and
delivers files one-by-one through the kernel's `install_file`
ctl verb on the target block device.

## EXAMPLES

    newshell hostowner
    /etc/install.hamsh

## SEE ALSO

hpm(1), newshell(1), fstab(5)
