# newshell - re-execve hamsh as another user

## NAME

newshell - the elevation idiom (hamsh builtin)

## SYNOPSIS

    newshell <user>
    newshell <user> -c <command>

## DESCRIPTION

`newshell` is the Hamnix replacement for sudo / su. It is a
hamsh builtin, not a /bin binary — that means it cannot be
exec'd from any code path the kernel would treat as privileged,
which removes setuid-binary attack surface.

`newshell <user>` prompts for `<user>`'s password (read from
`/dev/auth`, never from `/etc/shadow` directly), and on a
successful authentication, re-execve's `/bin/hamsh` in a fresh
process whose uid is the named user's. The new shell inherits
the current namespace but gains the new uid's authority.

`newshell <user> -c <command>` is the one-shot form: run
`<command>` as `<user>`, then exit back to the previous shell.

The canonical privileged user is `hostowner`. Package install
(`hpm install`) is gated to uid == hostowner.

## EXAMPLES

    newshell hostowner
    newshell hostowner -c 'hpm install ed'

## SEE ALSO

hamsh(1), hpm(1), passwd(1)
