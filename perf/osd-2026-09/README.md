# OSD performance study — 2026-09

Candidates for faster I/O in the classic OSD (`ceph-osd`, BlueStore), found by
reading the source of ceph **v21.3.0** (`cc6b5e2da077`). The starting points
were the traces in the blog post
[Ceph OSD Analysis](https://ming1.github.io/storage/ceph-osd-analysis): one
16 KiB read (§4.1) and one 16 KiB write on three OSDs (§4.2).

**Status:** found by code analysis and a perf profile; seven candidates and
one item of record 17 measured so far (2026-09-25, see [Measured so far](#measured-so-far)), two of
them as working fixes (03, 05). The other cost figures
are estimates from the code. All `file:line` references are to v21.3.0 under
`src/`.

## Measured so far

All on 3 BlueStore OSDs on brd ramdisks, where the device is not the
bottleneck and per-op cost shows up as OSD CPU, in interleaved rounds (3 per
leg). OSD CPU per op, context switches and BlueStore transactions per op are
the reliable metrics: legs that cannot affect a workload moved them by a few
percent. Client IOPS is not reliable here: in batch 4 two legs that change
nothing measurable (15, data digest) reached +16–18% IOPS against stock with
separate ranges, so IOPS changes below ~18% are not evidence. What limits
client IOPS in this 3-OSD setup was not measured.

| # | Candidate | Result | Raw data |
|---|-----------|--------|----------|
| 03 | EC dummy roll-forward: **the fix** (wait for quiet, 100 ms) | **confirmed**: BlueStore transactions per EC write 5.17 → 3.01, OSD CPU −24.3%, EC write IOPS +19%, latency −16%; same as the upper bound | ab3 |
| 05 | one wakeup per item, owner condvar (switch 05) | **confirmed**: OSD CPU per op −6% to −15% in every workload, context switches −17% to −40% (except the small-set read, −1%), no queue-depth-1 regression (the 16×1 config proxy doubled QD1 latency) | ab3, ab2 |
| 06 | obc cache 64 → 512 (500 objects per PG) | **confirmed** twice: hit rate 0.128 → 0.99, OSD CPU per read −10.5%, OSD read latency −18% | ab1, ab3 |
| 02 | cheap stats publish | mechanism confirmed (full publishes 594,936 → 320), CPU per op ~1%, within noise: **minor** | ab1 |
| 01 | commit callbacks before the PG lock | **not shown**: the 3-round mean looked 8–12% better, but that came from one slow stock round; against the other stock rounds, −2% to −6% write latency under mixed load and no change elsewhere | ab2 |
| 14 | delayed standalone messenger ACKs | **not shown**: OSD CPU per write −1.9%, within noise | ab3 |
| 15 | bounded PG log trim walk | **not shown** at 128 PGs per OSD: CPU per op −1.1% to +3.1%, within noise (profile share 0.5%) | ab4 |
| 17 (F5 only) | `osd_skip_data_digest = true` | **not shown**: CPU per op −1.6% to +3.6%, within noise (the option was passed to the OSDs; its effect was not checked separately) | ab4 |

Raw data: `results/2026-09-25-ab1.txt` … `-ab5.txt` (with per-round values).

### The four changes together

Switch 05 + the delayed EC roll-forward (100 ms) + obc cache 512 + switch 15
(leg `patches=05,15 rf_delay_ms=100 conf=[osd_pg_object_context_cache_count
= 512]`), against stock in the same batch (`results/2026-09-25-ab5.txt`;
every CPU range is separate from stock's, `qd1` by only 1 µs):

| workload | OSD CPU per op, stock → all | other |
|---|---|---|
| `rw4k` 4k write -t 64 | 652 → 604 µs (−7.4%) | context switches −42% |
| `rr4k` 4k random read -t 64 | 87.7 → 76.5 µs (−12.8%) | |
| `ec4k` EC 4k write -t 16 | 1004 → 732 µs (−27.1%) | EC write IOPS +18.5%, BlueStore transactions 5.2 → 3.0 per write |
| `qd1` 4k write -t 1 | 962 → 894 µs (−7.1%) | IOPS +11.6% |
| `orr` 4k read, 500 objects per PG | 56.3 → 47.3 µs (−16.1%) | OSD read latency −24% |
| `mixw` writes + reads | 897 → 842 µs (−6.2%) | |

- On the replicated workloads (`rw4k`, `rr4k`, `mixw`) the combined gain
  equals switch 05's alone in the same batch (−7.6% / −12.2% / −6.1%): the
  other changes do not act there, and they do not cancel it. On `ec4k` and
  `orr` the gains stack: the EC roll-forward and the obc cache add on top of
  switch 05 (05 alone: −4.6% and −4.3%). On `qd1` the combination (−7.1%) is
  a little less than 05 alone (−10.5%).
- A leg with switch 05 and obc 512 only was a little worse than 05 alone on
  the replicated workloads, but its ranges overlap and the full combination
  (which also has obc 512) matches 05 alone, so this is most likely noise.
- An earlier combined run (`-ab4.txt`) showed only −2% to −4% on the
  replicated workloads, with ranges overlapping stock's: in that batch stock
  used less CPU and the combined leg more than in batch 5 (drift between
  batches). So the replicated-path gain of the combination reproduced in one
  of two batches; switch 05 on its own reproduced in both of its batches
  (ab3, ab5).
- IOPS: see the note above; the EC IOPS gain is partly within what null legs
  reached, while its CPU (−27%) and BlueStore transactions (−42%) per write
  are robust.
- The two big-pool drops leave the 8 GiB ramdisks partly full; one combined
  leg filled a ramdisk and stopped after 5 of 6 workloads, so the combined
  leg has 2 `mixw` rounds instead of 3.

## Where the CPU goes

`perf record` of the 3 stock OSDs during 4k writes and 4k random reads (most
reads miss the BlueStore cache and read the ramdisk) (`common/osdprofile.sh`,
reports in `results/profile-2026-09-25/`). DWARF unwinding failed through
Ceph's C++ frames, so there are self times but no call trees. Percentages are
of all OSD CPU.

| | 4k write | 4k read |
|---|---|---|
| CPU by thread | `tp_osd_tp` 62%, messenger workers 20%, BlueStore kv/aio threads 16%, OpHistorySvc 1.3% | `tp_osd_tp` 67%, messenger 27%, `bstore_aio` 5% |
| system calls | 31%: futex 14.8% (wait 10.4%, wake 4.3%), `io_submit` 4.2%, `sendmsg` 4.1% | 42%: futex 17.8%, `sendmsg` 6.7%, `io_submit` 6.2% |
| `[vdso]` (the vDSO; its one hot function, shown only as address `0x989`, is taken to be `clock_gettime`) | 3.6% (1.4% in `tp_osd_tp`) | 4.8% (3.0% in `tp_osd_tp`) |
| allocation, `memmove`, bufferlist copies | ~9% | ~4% |
| PG log trim walk | 0.5% | — |

Futex waits and wakes, threads handing work to each other, are the largest
single cost class; that is what records 05, 01, 14 and 18 are about. Records
15–17 come from this profile.

## Candidates

Ranked by expected gain per line of change, updated with the measurements.

| # | Candidate | Area | Change | Expected gain | Workload |
|---|-----------|------|--------|---------------|----------|
| 03 | [EC dummy roll-forward op after most writes](03-ec-dummy-roll-forward/) | EC | small | **measured fix**: −42% BlueStore transactions, −24% OSD CPU, +19% IOPS per EC write | rbd 4k randwrite on EC |
| 05 | [One queued item wakes every thread of the shard](05-op-shard-wakes-all-threads/) | op queue | small | **measured fix**: −6% to −15% OSD CPU per op, every workload | any small I/O |
| 06 | [Object-context cache: 64 per PG, two getattrs per miss](06-obc-cache-small/) | PG | config + small | **measured**: −10.5% OSD CPU per read at 500 objects per PG | 4k randread, warm |
| 16 | [About 180 clock reads per client write](16-clock-reads-per-op/) | op tracker, OSD, messenger, BlueStore | small each | profile: vDSO 3.6–4.8% of OSD CPU | 4k write / read |
| 15 | [The PG log trim point search walks up to `target` entries](15-pglog-trim-walk/) | PG log | a few lines | **measured**: not shown at 128 PGs per OSD (profile 0.5%) | 4k write |
| 18 | [Thread handoffs and wakeups below the OSD op code](18-bluestore-thread-handoffs/) | BlueStore, messenger | small–high | profile: futex 14.8% | 4k write |
| 17 | [More per-op costs: allocations, peer lookups, copies](17-per-op-allocations-and-lookups/) | OSD | small each | profile bucket ~9%; F5 (data digest) **measured**: not shown | 4k write / read |
| 04 | [Deep scrub reads a whole chunk in one PG-lock hold](04-deep-scrub-no-yield/) | scrub | ~3 lines | client p99 during deep scrub | 4k writes + deep-scrub |
| 07 | [BlueStore submit (io_submit) under the PG lock](07-store-submit-under-pg-lock/) | BlueStore | medium | PG-lock time per write | 4k randwrite, few PGs |
| 08 | [Replicated read holds the PG lock across the device](08-replicated-read-holds-pg-lock/) | read | large | hot-PG latency on cache miss | mixed r/w, cold cache |
| 09 | [Background work reads under the PG lock](09-background-work-under-pg-lock/) | recovery, backfill | medium | client p99 during recovery | 4k writes + osd out |
| 10 | [Replica reply handled as a full op](10-replica-reply-full-op/) | messenger, op queue | small / medium | CPU per write | 4k write -t 64 |
| 11 | [Metadata per small write: dup keys, full info](11-per-write-metadata/) | PG log | small / format | KV ops per write | long 4k write |
| 12 | [Small CPU costs per op](12-cpu-per-op-small-wins/) | write, read | trivial each | CPU per op | 4k -t 64 |
| 13 | [EC: primary's own shard read loops back](13-ec-local-read-loopback/) | EC | small+ | 1/k of EC ops | rbd 4k on EC |
| 01 | [Commit callbacks run after the owner thread's op](01-oncommits-run-after-op/) | op queue | 3 lines | **measured**: not shown on a ramdisk (needs long ops) | rbd 70/30 randrw, cold cache, real disk |
| 14 | [A standalone ACK frame for every OSD-to-OSD message](14-msgr-standalone-acks/) | messenger | small | **measured**: not shown | 4k write |
| 02 | [PG stats published on every read and write](02-publish-stats-every-op/) | PG | small | **measured**: about 1 µs per op or less, within noise | 4k randread / randwrite |

Small fixes found along the way (details in the records):

- `PGRecoveryMsg::run` has a `switch` with no `break`, so a PUSH is counted in
  all six recovery queue-latency counters (record 09).
- `ECBackend::handle_sub_write` (record 13) and `ReplicatedBackend::do_repop`
  (record 17, F1) copy the whole missing set for each sub-write.

## Three themes

```
 1. The PG lock (or the one commit thread) is held across work that does not need it
      device submit (07), device read (08, 09, 04), other PGs' commits (01)
 2. Work done per op that is needed only now and then
      stats publish (02), EC roll-forward (03), full tracking of replica replies (10)
 3. Plain CPU: copies, allocations, shared cache lines (12, 06, 11)
```

## How to measure

- `common/measurement-switches.patch` (against v21.3.0) puts candidates behind
  the environment variable `CEPH_PERF_PATCHES` (for example `05,15`), read
  once per process: 01, 02, 03 (unsafe upper bound: no dummy op), 05, 14
  (in `libceph-common`), 15. `CEPH_PERF_EC_RF_DELAY_MS=<ms>` turns on the
  delayed EC roll-forward of record 03. One binary serves every leg; with
  the variables unset it behaves as stock. Measurement only: switch 02 is
  simpler than its proposed change (no `force` path), and switch 14 leaves up
  to 31 messages unacknowledged on an idle connection.
- `common/osdperf-leg.sh <build-dir> <outdir> <patches> [conf-line ...]` runs
  one leg: vstart with 3 BlueStore OSDs on `/dev/ram0..2` (`modprobe brd
  rd_nr=3 rd_size=8388608`), a replicated and an EC pool, then 4k write,
  random read, EC write, QD1 write, small-set random read and mixed
  workloads. For each it records IOPS, latency, OSD CPU per op (from
  `/proc`, idle subtracted), `tp_osd_tp` context switches per op, BlueStore
  transactions per op, the obc hit rate and OSD latency counters. The big
  write pools are deleted after use (8 GiB ramdisks); `RF_DELAY_MS=<ms>` sets
  the delayed roll-forward; `VERIFY=1` reads back and checks every EC object;
  `SETUP_ONLY=1` leaves the cluster running for another tool.
- Run the legs interleaved in rounds, with the baseline leg named `none`,
  then `common/osdperf-summary.py <ab-dir>` prints mean, change against
  `none` and [min..max] per workload:

  ```sh
  for r in 1 2 3; do
      osdperf-leg.sh $BUILD ab/r$r/none   none
      osdperf-leg.sh $BUILD ab/r$r/p03    03
      osdperf-leg.sh $BUILD ab/r$r/obc512 none "osd_pg_object_context_cache_count = 512"
  done
  osdperf-summary.py ab
  ```

  The first A/B run (`results/2026-09-25-ab1.txt`) predates the mixed
  workload, so it has no `mixw` section.
- `common/check02.sh <build-dir>` counts the full stats-publish calls with
  switch 02 off and on (bpftrace).
- `common/osdprofile.sh <build-dir> <outdir> [patches]` records all OSDs with
  `perf` during 4k writes and 4k reads and prints self time per symbol and
  per thread.

## A note on the trace numbers

The post's traces put about 30 uprobes on one write, and each uprobe hit costs
about 1–3 µs. The **order** of the events is exact; short gaps (7 µs, 33 µs)
overstate the real cost of the code between two probes. For example, §4.2's
33 µs between `ms_fast_dispatch` entry and `enqueue_op` is `create_request`,
two tracing spans and several probe hits. The message was already read and
decoded when `ms_fast_dispatch` was entered.

## Checked and ruled out

- No duplicate decode of `MOSDOp` or `MOSDRepOp`: `finish_decode()` is guarded.
- Log entries are encoded once for all replicas (`ReplicatedBackend.cc:1236`),
  and the replica data payload is shared by reference, not copied.
- No `dout` formatting on the hot path at default debug levels.
- No O(n) work per op in `do_request`: dup detection is a hash map.
- BlueStore does not verify the checksum again for cached buffers, and neither
  the read result nor the reply copies the data.
- Trimming the PG log with `omap_rmkeyrange` would be slower, not faster
  (record 11).
