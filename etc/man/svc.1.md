# svc - hamsh's service supervisor

## NAME

svc - start, stop, and inspect Hamnix services (hamsh builtin)

## SYNOPSIS

    svc start  <name>
    svc stop   <name>
    svc status [<name>]
    svc restart <name>

## DESCRIPTION

`svc` is a builtin of `hamsh` (not a /bin/svc binary). It is the
service supervisor: it reads `/etc/svc/<name>.hamsh`, parses the
key:value lines, and forks the named program as a child of PID 1.
Restart policy in the .hamsh file is `on-failure` with 1 s..30 s
exponential backoff.

Stdout and stderr of each service are captured to
`/var/log/svc/<name>.log`.

## SERVICE FILES

A service definition at `/etc/svc/<name>.hamsh` looks like:

    name: sshd
    exec: /bin/sshd
    restart: on-failure
    uid: 2                  # optional, runs as that uid

See `etc/svc/` for the in-tree definitions.

## EXAMPLES

    svc status              # show all services
    svc start sshd
    svc stop  sshd
    svc restart sshd

## SEE ALSO

hamsh(1), newshell(1)
