# One queued item wakes every thread of the op shard

| | |
|---|---|
| Area | op queue (`OSD::ShardedOpWQ::_enqueue`, `ContextQueue::queue`) |
| Change | small (switch 05 in `common/measurement-switches.patch`); must not undo `d1cf3fb80bc` |
| Expected gain | measured: OSD CPU per op −6% to −15% in every workload, context switches −17% to −40% (except the small-set read, −1%), queue-depth-1 latency −7% |
| Risk | medium (lost wakeups) |
| Status | **confirmed: the code fix is built and measured** (2026-09-25); unlike the config-only proxy it has no queue-depth-1 regression |

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
- Count the wakeups already sent (`wake_pending_workers`,
  `wake_pending_owner`): a thread that was signalled stays counted as
  sleeping until it re-takes the lock, so without this a second item can
  signal nobody (the lost wakeup the first review found). Every thread calls
  `woke_up()` after its wait returns.
- The owner must not start a timed wait (for a future mClock item) while
  commit callbacks are queued: their wakeup may have come before the wait.
- `stop_waiting` and the drain paths must signal both variables.

## Measured: the code fix (switch 05)

3 BlueStore OSDs on brd ramdisks, 3 interleaved rounds, 30 s per workload;
raw output and per-round values in `results/2026-09-25-ab3.txt`. Default
layout (8 shards × 2 threads).

| workload | OSD CPU / op, stock → switch 05 | `tp_osd_tp` context switches / op | other |
|---|---|---|---|
| `rw4k` 4k write -t 64 | 659 [633..683] → 592 [578..605] µs (−10.2%) | 12.1 → 7.3 (−40%) | |
| `rr4k` 4k read -t 64 | 89.0 [86.9..90.9] → 75.5 [73.5..77.0] µs (−15.1%) | 2.81 → 1.98 (−29%) | |
| `ec4k` EC write | 1017 [990..1052] → 937 [919..951] µs (−7.9%) | 16.5 → 12.9 (−22%) | |
| `qd1` 4k write -t 1 | 921 [891..945] → 865 [846..889] µs (−6.2%) | 11.7 → 8.5 (−28%) | IOPS +7.6%, client latency −7.2%, OSD write latency −9.2% |
| `orr` 4k read, small set | 57.9 [56.7..58.9] → 52.3 [50.4..53.8] µs (−9.6%) | ≈ 0 | |
| `mixw` mixed | 905 [895..919] → 827 [822..833] µs (−8.6%) | 11.5 → 9.6 (−17%) | |

- The CPU ranges do not overlap stock in any workload.
- The queue-depth-1 regression of the 16×1 proxy (below) is gone: at QD1 the
  fix uses less CPU (ranges do not overlap), and IOPS and latency are a little
  better (+7.6% / −7.2%, ranges overlap).
- Client IOPS at queue depth 64 did not go up (`rw4k` −2.6%, `rr4k` −5.6%,
  ranges overlap). In this 3-OSD setup OSD CPU is not what limits client
  IOPS; what does was not measured.
- Repeated in a later batch (`results/2026-09-25-ab5.txt`): switch 05 alone,
  OSD CPU per op `rw4k` −7.6%, `rr4k` −12.2%, `ec4k` −4.6%, `qd1` −10.5%,
  `mixw` −6.1% (ranges separate from stock), `orr` −4.3% (ranges overlap).
  With the other changes on as well, the replicated-path gain is about the
  same, so they do not cancel it.
- IOPS in that batch rose 12–14% on `rw4k`, `qd1` and `mixw`, but legs that
  change nothing reached +16–18% against stock in the batch before, so these
  IOPS changes are not evidence either way.
- The fix was reviewed twice. The first review found a lost wakeup (a thread
  that was signalled but had not yet re-taken the lock was still counted as
  asleep, so a second item could signal nobody); it is fixed by counting the
  wakeups in flight (`wake_pending_*`). The recheck checked that pending can
  never count too high, so a real sleeper is never skipped.

## Measured: config-only proxy

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

- The CPU ranges do not overlap the stock ranges, except at queue depth 1
  (below): fewer wakeups, less CPU, as the theory says.
- But the proxy is not a fix: at queue depth 1 it doubles the latency. The
  extra ~500 µs per op looks like waiting, not CPU; the cause was not
  investigated. The code fix, which keeps 2 threads per shard, is measured
  above and has no such regression.

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
