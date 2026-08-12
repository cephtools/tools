# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

bpftrace-based latency tracing tools for the fio → librbd → OSD → BlueStore
stack. Three standalone tools, no build system, no test suite. README.md is
the authoritative usage doc — keep it in sync when changing tool behavior,
output columns, or CLI flags.

- `fio-rbd-lat.sh` — POSIX sh script that *generates* a bpftrace program at
  runtime and `exec`s it. Runs on the fio client.
- `oplat.bt`, `wlat.bt` — bpftrace scripts run directly against a `ceph-osd`
  binary: `bpftrace oplat.bt <path-to-ceph-osd>`.

## Verifying changes

There is no test suite; verification is (a) does it still resolve/attach,
(b) do the numbers cross-check against the traced system's own counters.

- `RESOLVE_ONLY=1 ./fio-rbd-lat.sh` — preflight for the shell script: runs
  the whole resolution pipeline and prints the generated bpftrace program
  without attaching. Use this to check both the resolution logic and the
  generated code after any edit.
- Syntax-check a .bt script without a cluster by pointing it at any binary:
  probes won't attach but parse errors surface. Full verification needs a
  `ceph-osd` with symbols and a running workload.
- Cross-checks the tools are designed around: `oplat.bt`'s span equals the
  OSD's `op_w_latency`/`op_r_latency` counters (minus pre-tracking head);
  `wlat.bt`'s kv stages mirror BlueStore's `state_kv_queued_lat`/
  `kv_commit_lat` perf counters, and its END report prints the directly
  measured client latency next to the stage sum — if they disagree beyond
  rounding, the stage chain is broken.

## Architecture and invariants

**Nothing build-dependent is hardcoded.** This is the core design rule.
Symbol addresses, `struct io_u` field offsets, and ABI variants (e.g. the
`add_clat_sample` signature change in fio 3.39) differ per distro/build, so
`fio-rbd-lat.sh` resolves everything at runtime in a fallback chain:
`nm` → `nm -D` → separate debug file (build-id lookup → debuginfod →
distro debug-package install, disable with `NO_INSTALL=1`), and one batched
gdb DWARF query for struct offsets + the ABI probe. When adding a probe or
field, extend this chain rather than embedding an address or offset; every
resolved value has an env-var override (`IOU_OFF` etc.) for escape hatches.

**Correlation keys avoid struct offsets entirely where possible.** The OSD
scripts correlate request start/end through a single ABI-derived key:
`OpTracker::create_request` returns `OpRequestRef` (a one-pointer
`boost::intrusive_ptr`) via the Itanium sret convention, so at the
uretprobe `*(uint64*)retval` is the `OpRequest*` — the same pointer
`log_op_stats` gets as `arg1`. `wlat.bt` follows a `TransContext*` (`arg1`
of every stage function) through the BlueStore state machine. Prefer this
kind of key over DWARF-derived offsets in the .bt scripts, which
deliberately need no gdb step.

**.bt script conventions:**
- The traced binary is positional param `$1`; probes attach to mangled C++
  symbols with wildcards (`_ZN9BlueStore*_txc_state_procE*`) to survive
  signature changes. Wildcard attach takes ~10 s — the BEGIN banner tells
  the user when tracing is live.
- Ops can die mid-flight (error paths, replica ops), leaving stale map
  entries: guard downstream probes with `/@map[key]/`, `delete()` on
  completion, `clear()` the maps at END.
- END prints histograms in pipeline order and `clear()`s each after
  printing so bpftrace's exit doesn't re-print them.
- Silent while tracing (histograms only at Ctrl-C); per-event output only
  above a threshold (`fio-rbd-lat.sh`) or behind an opt-in flag
  (`wlat.bt --per-txc`).

**fio-rbd-lat.sh code generation:** the bpftrace program is a quoted
heredoc template with `__PLACEHOLDER__` tokens substituted by a single
`sed` pass at the end. New runtime-resolved values need a token in the
template plus an entry in that sed command. The rbd-engine half of the
program is appended conditionally — the script degrades to clat-only
tracing when rbd symbols are missing, and that path must keep working.

Comments in these files carry the measurement semantics (what each span
means, where it starts/ends relative to ceph's own counters, why a stage
reads the way it does). They are load-bearing documentation — update them
when changing probe points.
