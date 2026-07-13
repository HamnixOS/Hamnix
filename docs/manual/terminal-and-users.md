# Terminal, Shell & Users

This page covers getting a command line, the `hamsh` shell you'll be typing
into, how logins and users work, and how to become the machine's owner (the
Hamnix equivalent of root/sudo).

## Opening a terminal

Two ways:

- Press **Ctrl+Alt+T** anywhere on the desktop.
- Launch **Terminal** from the Applications menu (System category).

Either opens a window running `hamsh`, Hamnix's shell, at a `hamsh$` prompt.

## The `hamsh` shell in one minute

`hamsh` is Hamnix's own shell. If you know a little Python and a little `bash`,
you'll feel at home fast — but it is neither. It's a clean-sheet shell with a
**Python-flavored syntax** and its own small interpreter.

**It has two "skins" of the same language:**

- **Command lines**, like any shell — the first word is the command, the rest
  are arguments, and bare words are plain text:

  ```
  ls -la /dev
  cat /etc/passwd
  ```

- **Python-esque code** — assignments, `if`/`elif`/`else`, `for … in`, `while`,
  `def`, lists and dicts — using **curly braces `{ }`** instead of Python's
  indentation:

  ```
  port = 8080
  names = ["ada", "grace"]
  for n in names {
      echo hello $n
  }
  ```

  hamsh decides which kind a line is from its **first word**, deterministically —
  a control keyword (`if`, `for`, `while`, `def`, …) starts code; `name = …`
  is an assignment; anything else is a command. It never guesses.

A few everyday details:

- Use `$name` to drop a variable into a command, and `${ expr }` for an
  expression. When a list is used this way, **each element becomes exactly one
  argument** — there is no surprise word-splitting.
- Quoting only matters around spaces and special characters. Double quotes let
  `$name` expand; single quotes are literal.
- `*`, `?`, and `[…]` glob against the current namespace. That's the only
  automatic expansion.
- Environment variables live in the `/env` namespace — `$PATH` is the file
  `/env/PATH`.

For the full language, see [`docs/HAMSH_SPEC.md`](../HAMSH_SPEC.md).

## Running ordinary Linux programs

Hamnix keeps real Debian tooling in a **Linux compatibility namespace**. To use
it, wrap commands in `enter linux { … }`:

```
enter linux { apt-get update }
enter linux { sh }
```

Inside that block you're running genuine Debian binaries (`apt`, `dpkg`, `sh`,
`curl`, …) against a real Debian root, with networking to the actual Debian
archive. This is where you install Linux software; native Hamnix packages use
`hpm` instead.

## Logins and users

Each virtual terminal is started by a small `getty` program that runs
`/bin/login`. `login` prints a `login:` prompt, reads your username, then asks
for your password (with no echo), verifies it, switches to your account, moves
to your home directory, and starts `hamsh`.

Which accounts exist depends on how you booted:

- **Live image (before you install):** it auto-logs you in as a preset regular
  user named `live` (uid 1001) so the desktop just comes up — no password to
  type.
- **Installed system:** you log in as the **regular user** you named during
  installation (uid 1000). Its home directory already has `Desktop`,
  `Documents`, `Downloads`, and `Pictures`.

Two commands tell you who you are:

```
whoami
id
```

To change a password, use `passwd` (with no argument it changes your own).

## Becoming the owner (`hostowner`)

Hamnix's administrator account is **`hostowner`** (uid 1) — the equivalent of
root on Linux. It's the identity allowed to do privileged things like set other
users' passwords.

To get an owner shell from a regular login, use the built-in `newshell` — the
native Hamnix elevation command:

```
newshell hostowner
```

This opens a **new shell as `hostowner`**. It prompts for the **hostowner
password**; on a fresh install that's whatever was set during installation, or
the shipped default `hamnix` if none was chosen. The check is the password
itself — any user who knows the hostowner password can elevate; there is no
separate "sudoers" list. Change that default password with `passwd` as soon as
you can.

For a single privileged command without staying in an owner shell, use the
`-c` form:

```
newshell hostowner -c 'hpm install <package>'
```

`newshell <name>` switches to any other account the same way (password
required). The familiar `su` command also works as an alias if you prefer it,
but `newshell` is the native idiom.

> **How it actually works, briefly:** identity changes go through a kernel
> `/dev/auth` device. `newshell`/`su`/`login` hand it the target name and
> password; the kernel verifies the hash in `/etc/shadow` and hands back a token
> that proves the switch is allowed. Userland never reads or writes the shadow
> file itself — only the kernel does. This is why elevation works whether or not
> you were already the owner: the gate is the password proof, not your current
> uid.

There is no `sudo`: you either open a whole owner shell with `newshell
hostowner`, or run one command with `newshell hostowner -c '…'` — the Plan 9
style is a real elevated shell (or a scoped one-shot), not a per-command prefix
on your existing shell.
