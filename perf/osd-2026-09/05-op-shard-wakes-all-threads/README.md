# One queued item wakes every thread of the op shard

| | |
|---|---|
| Area | op queue (`OSD::ShardedOpWQ::_enqueue`, `ContextQueue::queue`) |
| Change | small, but must not undo `d1cf3fb80bc` |
| Expected gain | CPU and `shard_lock` contention per op; low-QD latency |
| Risk | medium (lost wakeups) |
| Status | **mechanism confirmed** with a config-only proxy (2026-09-25); the proxy has a queue-depth-1 regression; the code fix is not built |

## Summary

All threads of an op shard sleep on one condition variable, `sdata_cond`.

- `_enqueue` (`OSD.cc:11475`) calls `notify_all()` when an item lands in an
  empty queue. (When the queue was not empty, it calls `notify_one()` only if
  a thread waits for a future item, `waiting_threads`; that branch came with
  `e563e8a84ee`, 2020, for mClock.)
- `ContextQueue::queue` (`common/Finisher.h:176`) calls `notify_all()` on the
  same condition variable when commit callbacks arrive. Only the owner thread
  (`thread_index < num_shards`, `OSD.cc:11123`) runs them.

The other threads wake up, take `shard_lock`, find no work and sleep again
(`OSD.cc:11138-11142`). With the HDD defaults (1 shard × 5 threads) that is 4
useless wakeups per event; with the SSD defaults (8 shards × 2 threads), 1. A
size-3 write makes about 4 such events on the primary (client op, local
commit, 2 replica replies) and 2 on each replica.

## History: a plain `notify_one` is wrong

Commit `d1cf3fb80bc` (2020, "osd/OSD: wakeup all threads of shard") changed
`notify_one` to `notify_all`. `_enqueue` signals only on the empty→non-empty
edge, so with `notify_one` a second item never woke a second idle thread. Its
data, 4K randread at QD32: 8×2 gave 191k IOPS, 16×1 gave 263k, and 8×2 with
the patch 263.5k.

## Proposed change

- `_enqueue`: count idle threads under `sdata_wait_lock` and call
  `notify_one()` on **every** enqueue while a thread is idle (or waiting for a
  future item), not only on the empty edge. One wakeup per item, no herd.
- Commit callbacks: give the owner thread its own condition variable and make
  `ContextQueue` notify only that one. A `notify_one()` on the shared variable
  could wake a non-owner, and the commits would stall on an idle OSD.
- Then `_enqueue` must be able to wake the owner too: track idle threads per
  condition variable, and if the only idle thread is the owner, notify the
  owner's variable. Otherwise a new item waits until a busy thread finishes
  its op, which is the low-QD latency this change is meant to remove.
- `stop_waiting` and the drain paths must signal both variables.

## Measured

Setup: as in record 03 (3 BlueStore OSDs on brd ramdisks, 3 interleaved
rounds, 30 s per workload), with the pool drops that keep the ramdisks from
filling. Raw output, including the per-round values:
`results/2026-09-25-ab2.txt`.

Config-only proxy: 16 shards × 1 thread (`osd_op_num_shards_ssd = 16`,
`osd_op_num_threads_per_shard_ssd = 1`) against the default 8 × 2. With one
thread per shard, a wakeup can only reach the thread that has the work.

| workload | `tp_osd_tp` context switches / op | OSD CPU / op | other |
|---|---|---|---|
| `rw4k` 4k write -t 64 | 12.6 → 5.8 (−54%) | 632 → 584 µs (−7.5%) | OSD write latency lower in every round (1236–1272 µs against 1324–1710) |
| `rr4k` 4k read -t 64 | 2.80 → 1.65 (−41%) | 85.0 → 73.8 µs (−13.2%) | |
| `orr` 4k read, small set | 1.14 → 0.91 (−20%) | 56.1 → 49.2 µs (−12.4%) | |
| `mixw` mixed | 11.4 → 7.4 (−35%) | 874 → 800 µs (−8.5%) | |
| `ec4k` EC write | 16.6 → 11.2 (−33%) | 973 → 924 µs (−5.0%) | |
| **`qd1` 4k write -t 1** | 11.7 → 8.1 (−31%) | +3.1% | **IOPS 2086 → 1017 (−51%), OSD write latency 385 → 897 µs**, in all 3 rounds |

- The CPU ranges do not overlap the stock ranges: fewer wakeups, less CPU,
  as the theory says.
- But the proxy is not a fix: at queue depth 1 it doubles the latency. The
  extra ~500 µs per op looks like waiting, not CPU; the cause is not known
  yet (to check with an off-CPU trace of `tp_osd_tp`). The code change above
  (one wakeup per item, a separate wakeup for the owner thread) keeps 2
  threads per shard and still has to be built and measured.

## How to observe

- Voluntary context switches of the `tp_osd_tp` threads per op
  (`/proc/<pid>/task/*/status`), `perf sched record` + `perf sched latency`.
- bpftrace: count `OSD::ShardedOpWQ::_process` calls against
  `OSD::dequeue_op` calls; the difference is mostly empty wakeups.

## Workload

- `rados bench -b 4096 -t 1 write` and fio rbd 4k randwrite iodepth 1. The
  herd only happens when the queue drains, so low queue depth shows it.
- Zero-code check: `osd_op_num_shards_ssd=16`,
  `osd_op_num_threads_per_shard_ssd=1` (or `_hdd` 5 and 1) removes the herd
  with the same thread count.
