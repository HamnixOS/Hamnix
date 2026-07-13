# Welcome to Hamnix

Hamnix is a small, self-contained operating system with a friendly graphical
desktop. It boots straight to a MATE-style desktop — an Applications menu in the
top-left, a panel with a clock, virtual workspaces, and a set of built-in apps
for the things you do every day: browse the web, edit text, manage files, take
notes, do sums, watch the system, and take screenshots. Under the hood it's a
clean-sheet system inspired by the Plan 9 tradition, but you don't need to know
any of that to use it.

This manual is for people who just got Hamnix and want to use it. It doesn't
assume you're a programmer — just that you're comfortable with a computer. If
you want to install Hamnix, tour the desktop, or open a command line, start
below.

## Contents

- **[Installing Hamnix](installation.md)** — boot the live image, try it
  without touching your disk, then install to a real disk and boot into your new
  system.
- **[Desktop & Apps](desktop-and-apps.md)** — a tour of the desktop (the
  Applications menu, panel, workspaces, keyboard shortcuts) and what every
  built-in app does, with its real shortcuts.
- **[Terminal, Shell & Users](terminal-and-users.md)** — opening a terminal,
  the basics of the `hamsh` shell, how logins and user accounts work, and how to
  become the owner (administrator) of the machine.

## The 30-second version

- Get to the desktop by booting the **installer image** — it's also a full live
  desktop you can try before installing. It is **UEFI-only**.
- Open apps from the **Applications** menu (top-left). Switch between four
  **virtual workspaces** with **Ctrl+Alt+Left/Right**. Get a terminal instantly
  with **Ctrl+Alt+T**.
- The default shell is **`hamsh`** — Python-flavored, with `{ }` blocks instead
  of indentation.
- The administrator account is **`hostowner`**; become it with **`newshell hostowner`**.
