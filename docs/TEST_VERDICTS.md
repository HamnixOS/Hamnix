# Test verdicts — PASS, FAIL, INCONCLUSIVE

**Status:** reference documentation for the verdict vocabulary as shipped
(`scripts/_verdict.sh`, `scripts/run_gate.sh`, `scripts/gate_summary.sh`).

**Thesis:** a harness that only knows PASS and FAIL is *forced to lie* when a run
never got far enough to observe its own assertion. Hamnix has repeatedly been
burned by that lie. There are three outcomes, not two.

| Verdict | Meaning | Exit |
|---|---|---|
| `PASS` | The assertion was **observed** to hold. | `0` |
| `FAIL` | The assertion was **observed** to be violated. Real, actionable red. | `1` |
| `INCONCLUSIVE` | The assertion was **never observed**. Absence of evidence. **Not a pass.** | `125` |

Reach for `INCONCLUSIVE` when QEMU hit its timeout before the marker printed,
the guest timer was starved by host load, OVMF/socat/kvm or a required image was
missing, the daemon under test never came up, or a screendump came back empty.
In every one of those cases the code may be perfectly fine or catastrophically
broken — the run cannot tell you which, and it must not pretend otherwise.

## Why 125

`124` is owned by `timeout(1)`; a gate must distinguish "my QEMU timed out" (an
input) from "I am reporting inconclusive" (an output). `126`/`127` are reserved
by POSIX shells and `128+n` for death-by-signal. `125` already carries exactly
this meaning in the most widely deployed software that needs the concept:
`git bisect` uses `125` for "this commit cannot be tested — skip it".

Deliberately accepted caveat: `timeout(1)` itself exits `125` if it *internally*
fails (e.g. cannot fork). Gates never propagate a raw `timeout` status as their
own exit status — they capture it into `rc`, then decide a verdict — so the two
`125`s never meet. **Never `exit $?` straight out of a `timeout` call.**

## Writing a gate

```sh
. "$(dirname "$0")/_verdict.sh"

verdict_pass         mytag "42 heartbeats, 12 distinct ticks"
verdict_fail         mytag "heartbeat emitted but never rearmed"
verdict_inconclusive mytag "0 heartbeats; qemu rc=124 (host-starved)"
```

Each prints one machine-greppable line and **exits the whole script**, even from
inside a shell function — a gate that cannot observe its assertion has nothing
further to say. The line always has the shape `[<tag>] <VERDICT>: <reason>`, so

```sh
grep -E '^\[[^]]+\] (PASS|FAIL|INCONCLUSIVE):' gate.log
```

recovers any gate's verdict from its log.

### `verdict_pass_structural`

A `PASS` that is honest about being a **structural check only**: it grepped
source or log text and proved the code *says* the right thing. It did not render
a pixel, drive a mouse, or observe the runtime behaviour it is named after. It
exits `0` but brands the line `PASS (STRUCTURAL-ONLY)`. Per the arch audit the
whole `test_de_*.sh` family is in this category. Do not cite a structural pass as
evidence that a feature works.

## Running a battery

`run_gate.sh <gate> [args...]` runs one gate, retries **exactly once** if the
first attempt is `INCONCLUSIVE` (in case the host was transiently degraded), and
appends `verdict<TAB>gate<TAB>rc<TAB>log` to `$GATE_VERDICT_FILE`
(default `/tmp/hamnix-gate-verdicts.tsv`).

`run_gate.sh` exits `1` only on `FAIL`. A twice-`INCONCLUSIVE` gate exits `0`
**by design** — a degraded host must not manufacture red — and is recorded so
the summary can flag it. The verdict file, not the job's exit code, is the
source of truth for what was actually verified.

`gate_summary.sh` reads that file and renders the battery:

| Battery state | Headline | Exit (default) | Exit (`GATE_SUMMARY_STRICT=1`) |
|---|---|---|---|
| all gates passed | `VERIFIED` | `0` | `0` |
| any gate failed | `FAILED` | `1` | `1` |
| any gate inconclusive, none failed | `NOT VERIFIED` | `0` | `1` |
| no gates ran at all | (empty battery) | `1` | `1` |

An empty battery is a **failure**: a CI run that executed zero gates has
verified nothing.

## The rule

> **`INCONCLUSIVE` is not a pass.** A run that never observed its assertion is
> not evidence that the code works. Re-run on a quiet host, or install the
> missing dependency, before believing anything about that code.

Set `GATE_SUMMARY_STRICT=1` whenever a green battery is going to be *cited* as
verification — a release gate, a milestone claim, a "this works now" commit.
The permissive default exists so that a degraded host degrades to *silence*
rather than to a lie; strict mode exists so that silence can never be mistaken
for proof.

See also: `docs/loading_vs_working.md`.
