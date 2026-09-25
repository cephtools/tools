# OSD performance study — 2026-09

Candidates for faster I/O in the classic OSD (`ceph-osd`, BlueStore), found by
reading the source of ceph **v21.3.0** (`cc6b5e2da077`). The starting points
were the traces in the blog post
[Ceph OSD Analysis](https://ming1.github.io/storage/ceph-osd-analysis): one
16 KiB read (§4.1) and one 16 KiB write on three OSDs (§4.2).

**Status: code analysis only.** No candidate has been patched or measured
yet. Every cost figure is an estimate from the code. Each record says how to
measure it; `common/osdperf-ab.sh` runs the A/B workloads. All `file:line`
references are to v21.3.0 under `src/`.

## Candidates

Ranked by expected gain per line of change.

| # | Candidate | Area | Change | Expected gain | Workload |
|---|-----------|------|--------|---------------|----------|
| 01 | [Commit callbacks run after the owner thread's op](01-oncommits-run-after-op/) | op queue | 3 lines | write latency under mixed load | rbd 70/30 randrw, cold cache |
| 02 | [PG stats published on every read and write](02-publish-stats-every-op/) | PG | small | CPU on every op | 4k randread / randwrite |
| 03 | [EC dummy roll-forward op after most writes](03-ec-dummy-roll-forward/) | EC | small | fewer EC sub-writes and KV commits | rbd 4k randwrite on EC |
| 04 | [Deep scrub reads a whole chunk in one PG-lock hold](04-deep-scrub-no-yield/) | scrub | ~3 lines | client p99 during deep scrub | 4k writes + deep-scrub |
| 05 | [One queued item wakes every thread of the shard](05-op-shard-wakes-all-threads/) | op queue | small | CPU, low-QD latency | QD1 4k write |
| 06 | [Object-context cache: 64 per PG, two getattrs per miss](06-obc-cache-small/) | PG | config + small | CPU per op on RBD | 4k randread, warm |
| 07 | [BlueStore submit (io_submit) under the PG lock](07-store-submit-under-pg-lock/) | BlueStore | medium | PG-lock time per write | 4k randwrite, few PGs |
| 08 | [Replicated read holds the PG lock across the device](08-replicated-read-holds-pg-lock/) | read | large | hot-PG latency on cache miss | mixed r/w, cold cache |
| 09 | [Background work reads under the PG lock](09-background-work-under-pg-lock/) | recovery, backfill | medium | client p99 during recovery | 4k writes + osd out |
| 10 | [Replica reply handled as a full op](10-replica-reply-full-op/) | messenger, op queue | small / medium | CPU per write | 4k write -t 64 |
| 11 | [Metadata per small write: dup keys, full info](11-per-write-metadata/) | PG log | small / format | KV ops per write | long 4k write |
| 12 | [Small CPU costs per op](12-cpu-per-op-small-wins/) | write, read | trivial each | CPU per op | 4k -t 64 |
| 13 | [EC: primary's own shard read loops back](13-ec-local-read-loopback/) | EC | small+ | 1/k of EC ops | rbd 4k on EC |

Small fixes found along the way (details in the records):

- `PGRecoveryMsg::run` has a `switch` with no `break`, so a PUSH is counted in
  all six recovery queue-latency counters (record 09).
- `ECBackend::handle_sub_write` copies the whole missing set for each sub-write
  (record 13).

## Three themes

```
 1. The PG lock (or the one commit thread) is held across work that does not need it
      device submit (07), device read (08, 09, 04), other PGs' commits (01)
 2. Work done per op that is needed only now and then
      stats publish (02), EC roll-forward (03), full tracking of replica replies (10)
 3. Plain CPU: copies, allocations, shared cache lines (12, 06, 11)
```

## How to measure

`common/osdperf-ab.sh <build-dir> <outdir> [pool]` runs one A/B leg on a
vstart cluster: QD1 4k write, QD32 4k write, and cold-cache random reads with
concurrent 4k writes. For each workload it records `rados bench` IOPS and
latency, per-OSD perf-counter deltas, voluntary context switches of the
`tp_osd_tp` threads per op, and an `io_submit` histogram per OSD. Run it on
the stock build, then on each patched build or config change.

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
