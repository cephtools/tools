# EC pools send a dummy roll-forward op after most writes

| | |
|---|---|
| Area | EC write pipeline (`ECCommon::RMWPipeline::finish_rmw`) |
| Change | small: a PG-timer callback plus a queued PG work item (`common/measurement-switches.patch`, `CEPH_PERF_EC_RF_DELAY_MS`) |
| Expected gain | at low per-PG queue depth, up to one extra round per client write removed: about 3 sub-write messages and replies, and 3–4 KV commits (the written shards, the primary's own included) (estimate) |
| Risk | medium (rollback window) |
| Status | **confirmed; the fix is built and measured** (2026-09-25): it keeps the whole upper-bound gain on `ec4k` |

## Summary

When an EC write finishes and no other write is in flight in the PG,
`finish_rmw` sends an `ECDummyOp`: an empty transaction to every shard that
still needs to roll forward. It carries no log entries, but each of those
shards moves its roll-forward point, updates its PG info, and pays a KV commit
and a reply. With RBD random writes spread over many PGs, each PG
usually has at most one write in flight, so this runs after most writes.

## Theory

Checked in `ECCommon.cc` and `ECBackend.cc`:

```
 write N commits ─► finish_rmw                                  ECCommon.cc:1058
                    1. client reply (on_all_commit)             1062   the reply is not delayed
                    2. extent cache idle && N > can_rollback_to ?   1075-1076
                         └─► ECDummyOp, pg_committed_to = N          1080-1095
                             empty txn to each shard in pending_roll_forward
                             each: roll forward + PG info + KV commit + reply
```

- A shard joins `pending_roll_forward` whenever it gets a non-empty
  transaction (`ECClassicalOp::skip_transaction`, `ECBackend.cc:1135-1144`).
  Only the dummy removes it (`ECDummyOp::skip_transaction`,
  `ECCommon.cc:1037-1042`).
- Shards with an empty transaction are skipped (`ECCommon.cc:932`), so a
  normal write rolls forward only the shards it touches.
- Why the dummy exists: until a shard learns that `pg_committed_to` covers a
  version, it keeps the rollback state (generation objects made by
  `clone_range`, `ECTransaction.cc:1085`), and peering may have to roll back.
  An idle PG must not keep that forever.
- The legacy (non-optimized) EC path does the same (`ECCommonL.cc`).

The dummy costs no client latency, because it is sent after the reply. It costs
load: messages, KV commits and PG-lock rounds on each shard.

## Measured: upper bound

Setup: v21.3.0 RelWithDebInfo with `common/measurement-switches.patch`,
vstart, 3 BlueStore OSDs on brd ramdisks (the device is not the bottleneck,
so per-op cost shows up as OSD CPU), 64-CPU host, 3 interleaved rounds, 30 s
per workload (`common/osdperf-leg.sh`).
Values are the mean of 3 runs, with [min..max]. Raw output:
`results/2026-09-25-ab1.txt`.

Switch 03 disables the dummy entirely: this is the **upper bound**; it is
unsafe and only for measurement. Workload `ec4k`: `rados bench write -b 4096
-t 16`, EC pool k=2 m=1 (`allow_ec_overwrites`, `allow_ec_optimizations`),
32 PGs.

| | stock | dummy off | change |
|---|---|---|---|
| BlueStore transactions per client write | 5.18 [5.17..5.19] | 3.00 [3..3] | −42% |
| OSD CPU per client write (3 OSDs) | 1003 µs [993..1012] | 751 µs [713..774] | −25% |
| `tp_osd_tp` context switches per write | 22.1 | 14.4 | −35% |
| client IOPS | 19.8k [19.3k..20.2k] | 21.5k [20.9k..21.8k] | +8.9% |
| client latency | 0.81 ms | 0.74 ms | −8% |

- The ranges do not overlap.
- A write touches 3 shards, so 2.18 extra transactions per write means the
  dummy followed about 73% of the writes, as the theory said.
- This first run had no pool drops, so the ramdisks were filling up during
  it; the repeat on the clean layout (below) gave a larger IOPS gain (+18.5%).

## Measured: the fix

3 BlueStore OSDs on brd ramdisks, 3 interleaved rounds, 30 s per workload,
pool drops between the big workloads; raw output and per-round values in
`results/2026-09-25-ab3.txt`. Noise, judged from legs that cannot affect a
workload: OSD CPU per op a few percent, client IOPS up to ~15%.

Delayed roll-forward v2 at 100 ms, workload `ec4k` (4k writes to an EC k=2
m=1 pool, `-t 16`):

| | stock | delayed 100 ms (the fix) | dummy off (upper bound) |
|---|---|---|---|
| BlueStore transactions per client write | 5.17 | **3.01** | 3.01 |
| OSD CPU per client write | 1017 µs [990..1052] | **770 µs [753..780] (−24.3%)** | 779 µs (−23.4%) |
| `tp_osd_tp` context switches per write | 16.5 | 10.2 (−38%) | 10.2 |
| client IOPS | 17.9k [16.2k..19.0k] | **21.3k [21.1k..21.5k] (+19%)** | 21.3k (+18.5%) |
| client latency | 0.90 ms | 0.75 ms (−16%) | 0.75 ms |

All five changes are beyond noise (the ranges do not overlap). The A/B legs
do not verify data; three separate smoke legs with the delayed roll-forward
on (20 ms v1, then 100 ms v2 with switches 05 and 14; 8–10 s EC write runs)
read back and compared every EC object they wrote (`VERIFY=1`: 187,735,
176,635 and 177,179 objects written, the same numbers read and checked), with
no error.

## Proposed change

Delay the dummy until the PG has been quiet for a while, and let the writes
in between roll their own shards forward. The measured version (v2) works on
the PG timer that `ReplicatedBackend` already uses for its delayed
`pg_committed_to` update (`pct_callback_t`, `ReplicatedBackend.h:418`):

```
 finish_rmw:   idle && op->version > can_rollback_to
                 remember hoid / trim_to / reqid, rf_last_idle = now
                 if timer not armed: rf_first_idle = now, arm pg_timer (delay)
 timer fires   (pg_timer thread, PG lock taken by the timer)
                 interval changed or not primary      -> return
                 quiet < delay && now - rf_first_idle < 4 x delay
                                                      -> re-arm for the rest
                 else queue a PG work item: schedule_recovery_work(
                        bless_unlocked_gencontext(...))   (as ECBackend.cc:1060)
 work item     (op worker, PG lock held)
                 primary, pending_roll_forward not empty, cache idle,
                 committed_to > can_rollback_to  -> one dummy for all shards
 on_change:    cancel the timer
```

- **Wait for quiet:** a dummy is sent once per quiet period, not once per
  write. Writes during the delay carry `pg_committed_to` to the shards they
  touch; `pending_roll_forward` keeps the others, so one dummy covers them all.
- **Cap at 4 × delay:** without it, a steady low-queue-depth stream whose gaps
  are shorter than the delay would postpone the roll-forward of the shards it
  does not touch forever.
- **Not on the timer thread:** the dummy goes down to `queue_transactions`,
  which can block; `pg_timer` is one thread for all PGs of the OSD, so the
  timer only queues the work. The blessed context holds a PG reference and is
  dropped after an interval change.
- **Correctness** (independent review, 2026-09-25): an acknowledged write can
  never be rolled back (activation rolls every shard forward to the head);
  divergent entries after a failure in the window stay rollback-able; scrub
  skips generation objects; nothing else waits for the dummy. What changes:
  rollback state, the omap journal and PG log trimming lag by up to the delay
  (at most 4 × delay, plus the time the queued work item waits in the op
  queue, where mClock treats it as background work), and non-primary EC
  shard reads are redirected to the primary for that window.
- **Before upstreaming:** make the delay an OSD or pool option (the replicated
  equivalent, `PCT_UPDATE_DELAY`, is in seconds; 100 ms–1 s is sensible), and
  run an optimized-EC thrash test (`ceph_test_rados` with overwrites and OSD
  kill/revive).

## How to observe

- `debug_osd 20`: count the `cache idle` lines (`ECCommon.cc:1077`) against
  client writes.
- bpftrace: count `ECCommon::RMWPipeline::cache_ready` minus `start_rmw`. The
  dummy calls `cache_ready` directly and skips `start_rmw`.
- BlueStore KV commits (txc count) and EC sub-op messages per client op.

## Workload

fio rbd 4k randwrite on an EC data pool (k=4 m=2, `allow_ec_overwrites`,
`allow_ec_optimizations`, 128 PGs), at iodepth 1, 8 and 32. Expected today:
about one dummy per client write at iodepth 1–8. With the patch: close to 0,
except after the last write of a burst.
