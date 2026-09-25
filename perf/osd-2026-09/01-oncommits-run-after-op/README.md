# Commit callbacks run only after the owner thread finishes its op

| | |
|---|---|
| Area | op queue (`OSD::ShardedOpWQ::_process`) |
| Change | 3 lines |
| Expected gain | write-ack latency of every PG in a shard, under mixed load |
| Risk | low |
| Status | code analysis, not measured |

## Summary

In each op shard, one thread (the one with `thread_index < num_shards`) runs
the BlueStore commit callbacks of every PG in that shard. It takes the queued
callbacks at the start of `_process`, then locks a PG and runs a whole op, and
only then runs the callbacks. So every commit ack it holds waits for one full
op: about 377 µs for a write (post §4.2.5), or the whole device time for a read
that misses the cache (1.5 ms in post §4.1; 97 ms seen in one run).

```
 _process (owner thread)                                   OSD.cc
   context_queue.move_to(oncommits)       take the commits   11158
   dequeue item, find PG slot
   pg->lock()                                              11255
   qi.run()   ── the whole op, PG lock released at the end  11435
   handle_oncommits(oncommits)            run the commits    11448   <- late
```

## Theory

- `is_smallest_thread_index` (`OSD.cc:11123`) picks the owner. Commit
  `6c583fe756c` made it one fixed thread so commits of a shard stay in order.
- The PG callbacks are `BlessedContext`s (`PrimaryLogPG.cc:200`), and each
  one takes its own PG lock. Other callbacks can be in the queue too (for
  example a queued peering event); none of them needs a lock held by the
  caller, so none of them needs to run after the op.
- Nothing in the op depends on the commits running later. They were collected
  earlier, so they are older than the op.

## Proposed change

Run them after `shard_lock` is released and before `pg->lock()`:

```diff
     ++slot->num_running;

     sdata->shard_lock.unlock();
+    // Run the commit callbacks we took from context_queue before we
+    // block on this PG and run the op: they must not wait for it.
+    handle_oncommits(oncommits);
+    oncommits.clear();
     osd->service.maybe_inject_dispatch_delay();
     pg->lock();
```

Edge cases, checked in `OSD.cc:11240-11448`:

- Every exit after the dequeue already calls `handle_oncommits(oncommits)`:
  the races at 11265, 11277 and 11287, the no-PG paths at 11386 and 11391,
  the map-epoch check at 11400, and the normal end at 11448. The new call is
  inside `if (pg)`, so on that path the later calls run an empty list; the
  no-PG paths, and a PG just created there, behave as today.
- `goto retry_pg` (11295) jumps back above the new call; the list is empty by
  then, so nothing runs twice.
- **The call must not be placed under `shard_lock`.** `_process` takes
  `shard_lock` while holding the PG lock (11257), and a `BlessedContext` takes
  a PG lock. Running callbacks under `shard_lock` inverts the lock order.
- Order among commits is unchanged: one thread, FIFO.
- `handle_oncommits()` does not clear the list (`OSD.h:1818`), so the
  `clear()` is needed.
- Trade-off: the owner's own op now starts after the callbacks it took. They
  are usually short, but one can block on a PG lock held by a long op on
  another thread; then the owner's op waits for it. Measure the owner
  thread's op latency too.

What remains after the change: a `BlessedContext` for a PG whose lock is held
by a long op (a cache-missing read) still blocks the commits after it. A later
step could `try_lock` per PG and defer that PG's commits.

## How to observe

- bpftrace: time from `BlueStore::_txc_committed_kv` to
  `PrimaryLogPG::BlessedContext::finish` entry. The post's §4.2.7 shows this
  gap at 33 µs on an idle OSD; it should grow with load and shrink with the
  patch.
- Perf counters: `osd.op_w_latency` against `bluestore.txc_commit_lat`. The
  difference is the OSD-side overhead, including this wait.

## Workload

- Worst case: rbd 70/30 randrw, 16k, iodepth 32, with a cold cache
  (`ceph tell osd.N cache drop`), or `rados bench write` and `rados bench rand`
  on the same pool at once.
- Pure writes: `rados bench -b 4096 -t 32 write`.
- `osd_op_num_shards_ssd=1` puts all PGs in one shard and makes the effect
  larger.
- There is no config-only way to test this: with one thread per shard, that
  thread still runs the commits after each op.
