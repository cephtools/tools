# Background work reads the device under the PG lock, and mClock doesn't see it

| | |
|---|---|
| Area | recovery, backfill, scrub, mClock cost model |
| Change | medium |
| Expected gain | client p99 during recovery, backfill and scrub |
| Risk | medium |
| Status | code analysis, not measured |

## Summary

Recovery, backfill, scrub and snap trim are op-queue items. They run on the
`tp_osd_tp` threads and hold the PG lock while they read from the store. There
is no time budget per item. mClock charges them in bytes estimated before they
run, so it controls their throughput share, not how long they hold a PG or a
thread.

## Theory

| Item | Work under the PG lock | Reference |
|---|---|---|
| Recovery push | `build_push_op`: getattrs, omap iterate, `fiemap`, `readv` up to `osd_recovery_max_chunk` (8 MiB), crc — once **per target peer** | `ReplicatedBackend.cc:2238`; per-peer call at 2641 |
| Backfill scan | up to `osd_backfill_scan_max` = 512 objects listed, sync getattr each | `PrimaryLogPG.cc:14701` (primary), 14755 (replica) |
| Deep scrub | objects of up to 4 MiB: a whole chunk (up to 15 objects) in one hold; a larger object yields after each 4 MiB stride (record 04) | `pg_scrubber.cc:1483` |

- The object being recovered is already fenced by
  `obc->get_recovery_read()` (`PrimaryLogPG.cc:13956`), an obc read lock. That
  lock, not the PG lock, keeps writers out.
- **One PG can stall a whole shard.** `_process` blocks in `pg->lock()`
  (`OSD.cc:11255`). With 2 threads per shard (SSD default), a second op for the
  same PG parks the other thread too.
- mClock cost (`calc_scaled_cost`, `common/mclock_common.cc:332`) is
  `max(item_cost, osd_bandwidth_cost_per_io)`. Continuation items are charged
  about one I/O: `PGScrubResched` 4 KiB, `MSG_OSD_PG_SCAN` 0 bytes, a push
  reply 1. But a scrub continuation goes on through the rest of its chunk (up
  to about 60 MiB of small objects), a SCAN item does up to 512 getattrs, and a
  push reply can start the next 8 MiB push.
- Under mClock, the recovery, degraded-recovery, delete and snap-trim sleep
  options and `osd_scrub_sleep` are forced to 0
  (`OSD::maybe_override_sleep_options_for_qos`, `OSD.cc:10473-10505`).

## Proposed change

- Recovery: split `build_push_op` into plan (locked), read (unlocked, fenced by
  the recovery read lock), finalize and send (locked). Read once per object and
  share the buffer across peers when they need the same range.
- Backfill: the replica scans a range past `last_backfill`, where no writes
  happen, so its scan can run unlocked. Stopgap: `osd_backfill_scan_max`
  512 → 64.
- Charge continuation items by the work they do, and give background items a
  time budget (yield after N ms).

## Small bug found here

`PGRecoveryMsg::run` (`osd/scheduler/OpSchedulerItem.cc:214-227`) has a
`switch` on the message type with no `break` statements. A PUSH is counted in
all six `l_osd_recovery_*_queue_lat` counters, so those counters can't be
trusted per message type. Fix: add the `break`s.

## How to observe

bpftrace: PG-lock hold and wait histograms grouped by the type of the item
holding the lock. Record the type at each item's `run()` entry per thread,
measure hold time from the `PG::lock` return to `PG::unlock`, and wait time on
`PG::lock`.

## Workload

`rados bench -t 16 -b 4096 write` for 300 s. During it, in turn:

- `ceph osd out N` (recovery and backfill);
- `ceph pg deep-scrub <pgid>` on a PG full of 4 MiB objects;
- `rbd snap rm` after overwriting a snapshotted image (snap trim).

Compare client p99 with the baseline. Config-only A/B:
`osd_backfill_scan_max` 512 vs 64, `osd_scrub_chunk_max` 15 vs 3,
`osd_op_num_threads_per_shard_ssd` 2 vs 4.
