# read - read a line from stdin (hamsh builtin)

## NAME

read - read one line from stdin into a shell variable

## SYNOPSIS

    read VAR
    read -s VAR

## DESCRIPTION

`read VAR` reads a single line from stdin and stores it in the
hamsh variable `VAR` (without the trailing newline). It is a
hamsh builtin, not a /bin binary — there is no separate process.

`read -s VAR` is the silent form: the typed bytes are not echoed.
Used for password prompts (the form `newshell` uses internally).

## EXAMPLES

    echo -n "name? "
    read NAME
    echo "hi $NAME"

    echo -n "password: "
    read -s PW

## SEE ALSO

hamsh(1), newshell(1)
