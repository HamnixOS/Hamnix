# Installing Hamnix

This page walks you from a downloaded Hamnix image to a running, installed
system on your own disk.

## What you get to install from

Hamnix ships as a **single UEFI installer image**: `build/hamnix-installer.img`.
It is a complete, bootable "live" desktop — you can try the whole system before
you commit anything to disk. There is no separate "live CD" and "installer";
they are the same image.

A few things worth knowing up front:

- **UEFI only.** Hamnix boots through UEFI firmware. There is **no BIOS / legacy
  / CSM path and no GRUB** — the image carries a small native UEFI boot program
  (`\EFI\BOOT\BOOTX64.EFI`) that loads the kernel directly. If your machine is
  set to "Legacy" or "CSM" boot, switch it to UEFI first.
- **Everything runs from RAM while you're trying it.** The installer loads its
  entire root filesystem into memory at boot, so the live desktop never depends
  on the install medium after startup. This is deliberate — it lets Hamnix
  install onto machines whose USB stack it can't yet drive.
- **Networking works out of the box.** A network card is attached by default,
  and inside the Linux compatibility namespace `apt`/`dpkg` reach the real
  Debian archive over the network. (See
  [Terminal & Users](terminal-and-users.md) for how the Linux namespace works.)

## Step 1 — Boot the live image

Write `hamnix-installer.img` to a USB stick (or, in a virtual machine, attach it
as a disk), make sure the machine is in **UEFI** mode, and boot from it.

To try it in a VM on a Linux host, the repository ships a helper that sets
everything up correctly (writable UEFI firmware, a blank target disk, and a
network card):

```
bash scripts/run_installer.sh
```

A window opens and Hamnix boots straight to its desktop.

## Step 2 — Try it before you install

You are now in a full live desktop. The **Applications** menu (top-left),
the panel, and every app described in [Desktop & Apps](desktop-and-apps.md)
are all live. Open the Web Browser, poke at the Files manager, run the
Calculator — nothing you do here touches your disk. This is your chance to see
whether Hamnix likes your hardware before you install.

## Step 3 — Install to a disk

When you're ready, launch **Install Hamnix** from the Applications menu (it is
listed under System, and only appears on the live medium). If you prefer the
terminal, open one (Ctrl+Alt+T) and run:

```
install
```

The installer does a real, Debian-style install — not a disk-image copy:

1. It lists the disks it can install to and asks which one to use. **The chosen
   disk is erased**, so pick carefully.
2. It partitions that disk as **GPT** with an **ESP** (the small UEFI boot
   partition) and an **ext4 root**.
3. It formats both, copies the UEFI boot program and kernel onto the ESP, and
   then **installs the base system as packages** onto the ext4 root using
   Hamnix's own package manager (`hpm`).
4. It writes out your accounts and a real home directory (see below).

There is nothing to babysit; when it finishes it tells you the disk is now
independently bootable.

> Under the hood the same work can run unattended. On a keyboard-less machine
> the file `/etc/install_nvme.hamsh` runs `install --auto`, which picks the
> first installable disk and installs without prompting. As a normal user you'll
> use the interactive **Install Hamnix** app, which always confirms the erase.

## Step 4 — First boot

Remove the install medium and boot the machine normally. UEFI finds the boot
program on your new disk's ESP, loads the kernel, and the kernel mounts your
ext4 root. You now have a persistent, installed Hamnix.

On that freshly installed system you get:

- **A regular user account** (uid 1000) — the name is the one chosen at install
  time. Its login shell is `hamsh` (see
  [Terminal & Users](terminal-and-users.md)).
- **A real home directory** with the standard folders already created:
  `Desktop`, `Documents`, `Downloads`, and `Pictures`.
- **An owner/administrator account** called `hostowner` (the Hamnix equivalent
  of root). If no password was set for it at install time, it uses the shipped
  default password `hamnix` — change it (`passwd`) as soon as you log in.

See [Terminal & Users](terminal-and-users.md) for how to log in, open a shell,
and become the machine's owner.
