# scripts/_hamsh_log.sh — hamsh interactive-log assertion helpers.
#
# WHY THIS EXISTS
#
# hamsh's interactive prompt now has a full line editor (user/hamsh.ad
# :: ed_readline). Like any real interactive shell, it ECHOES what you
# type and repaints the line as the cursor moves. When a test drives
# hamsh over the serial console, that echo is recorded in the captured
# serial log alongside genuine command output.
#
# A naive `grep -F "MARKER" log` therefore matches the MARKER both
# when a command actually PRINTED it and when the test merely TYPED
# `echo MARKER` (the editor echoed the keystrokes back). Tests that
# assert a marker is absent — or count how many times it ran — need to
# look at command OUTPUT only, not input echo.
#
# THE DISCRIMINATOR
#
# The line editor always repaints the prompt (`hamsh$ ` or the `> `
# continuation) at the start of the line it is editing, and the whole
# interactive edit of one input line lands on a SINGLE serial-log line
# (the editor uses CR, not LF, to repaint — only Enter emits a
# newline). Genuine command output, by contrast, is written on its own
# line with no prompt. So:
#
#   * a log line containing the marker AND a prompt  -> input echo
#   * a log line containing the marker and NO prompt -> command output
#
# These helpers grep only the command-output lines.

# _ho_outlines <logfile> — emit just the command-output lines (drop any
# line carrying a shell prompt, i.e. input being echoed back).
_ho_outlines() {
    grep -vE 'hamsh\$|\] > ' "$1" 2>/dev/null || true
}

# hamsh_ran <logfile> <marker> — succeeds iff <marker> appears in
# genuine command output (not merely typed at the prompt).
hamsh_ran() {
    _ho_outlines "$1" | grep -F -q "$2"
}

# hamsh_ran_count <logfile> <marker> — number of command-output lines
# containing <marker>.
hamsh_ran_count() {
    _ho_outlines "$1" | grep -F -c "$2" || true
}
