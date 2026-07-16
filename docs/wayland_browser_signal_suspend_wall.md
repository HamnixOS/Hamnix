# Firefox / WebKit Wayland-bridge startup wall — pinned to missing preemptive signal delivery

Status: **diagnostic round — primitive pinned, fix proposed.** Applies to issues
#237 (Firefox) / #238 (WebKitGTK MiniBrowser); supersedes the "engine-internal
circular wait, not fixable from our side" framing in
`project_firefox_startup_deadlock` for the WebKit arm and identifies a concrete,
kernel-side, *shared* root cause for BOTH GTK browsers.

## TL;DR

Both Firefox (Gecko/SpiderMonkey) and WebKitGTK (JSC/WTF) wall at the **exact same
rung** — post `xdg_wm_base` bind, pre `get_xdg_surface` — while single-threaded
`gtk_hello`, `foot` and Qt5 map + paint fine on the same compositor. The distinguishing
factor is **multi-threaded stop-the-world**: JSC's WTF and SpiderMonkey both suspend a
*running peer thread* by sending it a POSIX signal and blocking on a semaphore that the
signal handler must post. Hamnix's Linux-ABI **delivers signals only cooperatively** —
at a syscall-return boundary or a `yield_to_others` — and has **no preemptive delivery**
from the timer-tick return-to-user path. A thread spinning in userspace (a running
mutator / JIT / init loop) therefore *never* receives the suspend signal, never runs its
handler, never posts the semaphore, and the suspender (and the whole engine startup)
deadlocks.

This is NOT any of the previously-disproven paths (compositor correctness, staging /
icon cache, host round-trip, futex WAIT/WAKE keying, GLib self-wake). Those tests never
had a thread *ignore a posted signal while spinning in userspace* — the one condition
that triggers this.

## The pinned primitive (code evidence)

`kernel/sched/core.ad:9084-9089` — the signal machinery's own "Delivery points" note:

```
# Delivery points:
#   1. yield_to_others — after each cooperative yield (covers
#      blocking syscalls like SYS_WAITPID / pipe reads).
#   2. signal_check_and_handle called from do_syscall's tail in
#      arch/x86/kernel/syscall.ad before sysret — covers
#      synchronous syscalls that didn't yield.
```

`arch/x86/kernel/time.ad:270-271` — the timer IRQ's own admission:

```
    # happens when the signal'd task next hits a syscall return
    # or a yield_to_others — no preemption-with-signals yet.
```

So `signal_post` (`core.ad:9128`) latches `sig_pending` and force-wakes a task that is
blocked in `STATE_WAIT` (good — a *parked* target is fine), but a task **executing in
CPL=3 with no syscall** is only serviced when it next traps. There is no
`signal_check_and_handle` on the timer-interrupt / return-to-user path (that path only
delivers *synchronous fault* signals — `deliver_fault_sigsegv` in `trap_diag.ad`, not
async `sig_pending`).

## Why this is exactly what WebKit/Firefox hit

WTF's `Thread::suspend()` (Linux) is a signal + semaphore handshake. The staged
`libjavascriptcoregtk-4.1.so.0.10.11` imports exactly the ingredients:

```
U pthread_kill@GLIBC_2.34      # suspender -> send SigThreadSuspendResume to target
U sem_wait@GLIBC_2.34          # suspender -> block until the handler acks
U sem_post@GLIBC_2.34          # target handler -> ack that context is saved
U sigaction@GLIBC_2.2.5        # install the suspend/resume handler
U sigsuspend@GLIBC_2.2.5       # target handler -> wait to be resumed
```

Sequence, and where it wedges on Hamnix:

1. Collector/helper thread `T_s` wants to scan mutator `T_t`'s stack (JSC GC /
   sampling / `Thread::visitStack`). It calls `pthread_kill(T_t, SIG)` then `sem_wait`.
2. On Hamnix, `pthread_kill` -> `tgkill` -> `signal_post(T_t, SIG)`: the bit is latched
   in `T_t.sig_pending`.
3. If `T_t` is **running in userspace** (JIT/init/mutator loop, no syscall), the signal
   is never delivered — no preemptive path exists. `T_t` keeps executing.
4. `T_t` therefore never runs its handler, never `sem_post`s.
5. `T_s` is parked in `sem_wait` (a `FUTEX_WAIT`) — forever (or retrying after a
   timeout, forever).

This is a one-to-one match with the observed signature (`project_firefox_startup_deadlock`):

- `[nosys-wd]`: the **main thread SPINS in userspace, no syscall for hundreds of ticks**
  = `T_t`, the running mutator being suspended.
- Sibling worker(s) **park in `sem_wait`/`FUTEX_WAIT` -> `202 => -110` (ETIMEDOUT)** =
  `T_s`, the suspender blocked on the ack semaphore.
- Firefox's "**no wake is ever ISSUED on the stuck word**" (WAKE-side probe): correct —
  the `sem_post` that would wake the suspender lives in a signal handler that never runs.
- Single-threaded `gtk_hello` / `foot` / Qt5 never suspend a running peer thread, so
  they never exercise this path and map fine.

### Confidence: strong for WebKit, consistent-but-unconfirmed for Firefox

The WebKit/JSC arm is the **corroborated** one: `libjavascriptcoregtk` imports the full
signal-suspend set (`pthread_kill` + `sem_wait`/`sem_post` + `sigaction` + `sigsuspend`),
and the `[nosys-wd]` spin-in-userspace + parked-sibling-in-`sem_wait` signature is a
textbook match. The staged Firefox `libxul.so` also imports `sem_post`/`sem_wait`/
`sigaction`, so the same mechanism is *plausible* there — but Gecko's earlier
symbolicated diagnosis pointed at a **Rust-std condvar** (software-WebRender render-thread
readiness), which could instead be a plain cross-thread condvar whose notifier never runs
for an unrelated reason. Treat Firefox as "consistent with, pending its own `[nosys-wd]`
RIP resolution." Fixing the preemptive-delivery gap is necessary for the WebKit arm
regardless and is the right next experiment for both.

## Why the earlier "not fixable from our side" verdict was too pessimistic

The earlier rounds correctly cleared the *futex delivery* layer (WAIT/WAKE keying,
directed-wake) and the GLib cross-thread self-wake — but those probes all park the target
in a **blocking syscall**, where `signal_post`'s `wq_wake_one_signal` + the syscall-tail
`signal_check_and_handle` do deliver correctly. The missing case is a target **spinning
in userspace**, which none of the synthetic gates reproduced. The fix is a legitimate
*kernel* change (preemptive signal delivery), not a Firefox patch and not Linux-userland
reimplementation.

## Proposed fix (kernel, linux_abi-scoped)

Implement preemptive async-signal delivery on the return-to-user path, the Hamnix analog
of Linux's `TIF_SIGPENDING` check in `exit_to_user_mode_loop`:

- On the **timer IRQ return path** (and any IRQ that returns to CPL=3), if
  `current` is a Linux-ABI task (`is_linux_userspace`) whose `sig_pending & ~sig_mask`
  has a bit with an installed handler, build the Linux `rt_sigframe` against the
  *interrupted* iret frame and redirect CPL=3 RIP to the handler.
- **Concrete template already in-tree:** `deliver_fault_sigsegv(iret_frame)` in
  `arch/x86/kernel/trap_diag.ad` does exactly this shape today — it constructs a full
  sigframe *from the trap's `iret_frame`* (interrupted user RIP/RSP/RFLAGS) and stages
  the handler back into that frame, rather than from the syscall-entry kstack slots that
  `deliver_signal_to_user` reads (`saved_user_rip_ptr()` etc.). So the increment is: an
  async-signal analog of `deliver_fault_sigsegv` — call it from the timer path with the
  timer's `iret_frame`, pick the lowest deliverable pending signal, and stage its handler.
  This reuses proven machinery (siginfo/ucontext build, STAC/CLAC user-stack store, red
  zone, `sig_in_handler` latch) and avoids the harder problem of retrofitting the
  syscall-slot-based `deliver_signal_to_user` onto an IRQ frame.
- Constraints to respect: run from the return path with IRQs in the right state (not
  nested mid-handler); STAC/CLAC around the user-stack frame store (same discipline as
  the syscall-tail delivery and the SMAP loader-fault fix); **Linux tasks only** — native
  Plan 9 tasks use the note mechanism (`sys/src/9/port/sysnote.ad`) and MUST NOT be
  touched (the Layer-1/Layer-2 boundary in the `core.ad:9091` note).
- Default-disposition (no handler) async signals to a spinning task can keep today's
  semantics (they terminate at the next boundary); the browser case always installs a
  handler via `sigaction`, so handler-installed delivery is the necessary-and-sufficient
  increment.

## Suggested repro gate (engine-free, cheap)

A 2-thread u-binary that reproduces the primitive without WebKit:

- Thread B installs a `SIGUSR1` handler (via `sigaction`) that `sem_post`s a semaphore,
  then B spins in a **pure userspace loop** (`while (!flag) { }`, no syscalls) with the
  handler flipping `flag`.
- Thread A `pthread_kill(B, SIGUSR1)` then `sem_wait`s for the ack, with a bounded
  `alarm`/timeout.
- On real Linux the handler preempts B's spin, posts, and A proceeds. On Hamnix pre-fix A
  hangs (B never leaves the spin); post-fix it completes. This is the minimal gate that
  turns the fix green and guards against regressions — far cheaper than the 6G WebKit boot.
