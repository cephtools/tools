# EC pools send a dummy roll-forward op after most writes

| | |
|---|---|
| Area | EC write pipeline (`ECCommon::RMWPipeline::finish_rmw`) |
| Change | small (a timer) |
| Expected gain | at low per-PG queue depth, up to one extra round per client write removed: about 3 sub-write messages and replies, and 3–4 KV commits (the written shards, the primary's own included) (estimate) |
| Risk | medium (rollback window) |
| Status | **confirmed** (upper bound measured, 2026-09-25); the timer version is not yet built |

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

## Measured

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
- A real fix (the delayed dummy below) keeps part of the dummy's cost, so its
  gain lies between the two columns.

## Proposed change

Delay the dummy with a short timer and let the next write do the job:

```
 finish_rmw:  idle && committed_to > can_rollback_to  ->  arm_roll_forward()  (once)

 arm_roll_forward():
   osd->mono_timer.add_event(delay /* 20-100 ms */,
     [o, epoch, spgid] { o->queue_ec_roll_forward(epoch, spgid); });

 on fire (PG queue item, PG lock held):
   if pg_has_reset_since(epoch): return
   if extent_cache.idle() && committed_to > can_rollback_to:
     submit ECDummyOp(pg_committed_to = committed_to)   // today's code, one batch
```

- The tree already has this pattern: `PG::schedule_renew_lease`
  (`PG.cc:1620`) goes `mono_timer` → queue a PG item → epoch guard.
- A write inside the delay carries `pg_committed_to` to the shards it touches.
  `pending_roll_forward` keeps the others, so one dummy per idle period covers
  all of them.
- Risks: the rollback window and the life of generation objects grow by at
  most the delay. The epoch guard makes a timer from an old interval a no-op.
- To check: `RMWPipeline::on_change` (`ECCommon.cc:1102`) does not clear
  `pending_roll_forward` today. Check whether the first write of a new interval
  (`first_write_in_interval`) covers that.

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
