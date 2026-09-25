# PG stats are published on every read and every write

| | |
|---|---|
| Area | PG stats (`PG::publish_stats_to_osd`) |
| Change | small |
| Expected gain | measured: about 1 µs per op or less, not resolvable from run-to-run noise |
| Risk | low, if the counters stay exact (see below) |
| Status | **mechanism confirmed, gain not measurable** (2026-09-25) |

## Summary

`publish_stats_to_osd()` rebuilds the PG's `pg_stat_t` for the mgr. It is
called on every successful read (`complete_read_ctx`,
`PrimaryLogPG.cc:9368`) and on every completed write (`eval_repop`,
`PrimaryLogPG.cc:11675`). The OSD sends these stats to the mgr only every
`mgr_stats_period` (5 s).

## Theory

`PG::publish_stats_to_osd` (`PG.cc:797`) does, per op:

```
 update_stats_wo_resched(scrubber->get_schedule())      scrub schedule query
 lock pg_stats_publish_lock
 prepare_stats_for_publish                              PeeringState.cc:4407
   ceph_clock_now
   update_calc_stats, update_blocked_by
   pg_stat_t pre_publish = info.stats                   vectors, map, interval_set
   pre_publish.stats.add(unstable_stats), purged_snaps loop
   pre_publish == *pg_stats_publish ?  -> "no change", return
   else ++reported_seq, last_fresh = now, ...          -> move into pg_stats_publish
```

The "no change" shortcut never fires under I/O. Reads add their counters to
`unstable_stats` (`PrimaryLogPG.cc:9162`) and writes change `info.stats`, so
every op takes the full path.

Side effects the function must keep: it sets `PG_STATE_INCONSISTENT` and
`PG_STATE_DEGRADED` from the stats, and refreshes `last_fresh` and
`reported_epoch`.

## Measured

Setup: v21.3.0 RelWithDebInfo with `common/measurement-switches.patch`,
vstart, 3 BlueStore OSDs on brd ramdisks (the device is not the bottleneck,
so per-op cost shows up as OSD CPU), 64-CPU host, 3 interleaved rounds, 30 s
per workload (`common/osdperf-leg.sh`).
Values are the mean of 3 runs, with [min..max]. Raw output:
`results/2026-09-25-ab1.txt`.

The mechanism is confirmed. bpftrace counted the full path while 10 s of
random reads ran (the probes count for about 22 s: 12 s idle, then the reads;
`results/2026-09-25-check02.txt`, `common/check02.sh`):

| | reads | `publish_stats_to_osd` | `prepare_stats_for_publish` (full path) |
|---|---|---|---|
| stock | 594,935 | 594,936 | 594,936 |
| switch 02 | 544,086 | 544,087 | 320 |

So stock runs one full publish per op, and switch 02 removes 99.94% of them
(320 = 32 PGs × one full publish per second × 10 s, as designed). But OSD CPU
per op hardly moved:

| workload | stock | switch 02 | change |
|---|---|---|---|
| `rr4k` 4k random read | 84.5 µs [83.1..85.8] | 83.6 µs [83.0..84.6] | −1.1% (ranges overlap) |
| `rw4k` 4k write, size 3 | 646 µs [639..657] | 653 µs [643..667] | +1.2% (ranges overlap) |

The mean CPU saving on reads is about 1 µs per op, but three runs cannot
separate it from noise (any saving up to about 3 µs fits the ranges). Read
latency fell 5.1% with non-overlapping ranges, but switch 03, which cannot
touch a replicated pool, moved the same metric by −6.3% (and CPU per op by
−1.2% to −2.6%): noise in these runs is larger than the change. So the gain is small and not proven;
the change is still correct, but it is a minor item, not a top candidate.

The measured switch is simpler than the proposal above: it has no `force`
path, so a state change is only noticed by the state compare.

## Who reads the result

- `OSD::collect_pg_stats` (`OSD.cc:7924`), every `mgr_stats_period`.
- `ceph tell osd.N flush_pg_stats` (`OSD.cc:3168`). It sends what is published
  **now**. QA tests do "write, flush_pg_stats, check `ceph df`", so the
  counters must stay exact.

So a plain rate limit (publish at most once per second) is wrong: after a
flush, `ceph df` and `ceph pg dump` could show counters up to 1 s old.

## Proposed change

Keep the counters exact on every op, and rate-limit everything else:

```cpp
void PG::publish_stats_to_osd(bool force)
{
  if (!is_primary())
    return;
  auto now = ceph::coarse_mono_clock::now();
  if (!force && pg_stats_publish &&
      recovery_state.get_state() == pg_stats_publish->state &&  // no state change
      now - last_full_publish < full_publish_interval) {          // e.g. 1 s
    std::lock_guard l{pg_stats_publish_lock};
    pg_stats_publish->stats = recovery_state.get_info().stats.stats;  // counters only
    pg_stats_publish->stats.add(unstable_stats);
    return;
  }
  last_full_publish = now;
  // ... existing full path ...
}
```

- The mgr accepts an update whose `(reported_epoch, reported_seq)` equals the
  one it has; it only drops strictly older ones (`mgr/ClusterState.cc:125`).
  So the cheap path needs no sequence bump.
- State changes take the full path. Callers after peering or recovery
  completion should pass `force = true`.
- The cheap path updates only the object counters. It skips
  `update_calc_stats`, so after a flush `ceph pg dump` can show `version`,
  `log_size`, `log_dups_size`, `snaptrimq_len` and the degraded / misplaced
  counts up to one interval old. `ceph pg query` recomputes them
  (`PeeringState.cc:4601`), so it is not affected.
- Adding a parameter changes the `PeeringListener` interface
  (`PeeringState.h:383`). A separate cheap method, called only from the two
  per-op sites (`PrimaryLogPG.cc:9368`, `11675`), is simpler.
- To check: `get_state()` against `info.stats.state` (the full path copies the
  state into `info.stats`), and whether `num_objects_degraded` changes need the
  full path to set `PG_STATE_DEGRADED` at once.

## How to observe

- bpftrace: count and latency histogram on `_ZN2PG20publish_stats_to_osdEv`.
  Today the count per second equals IOPS.
- `perf record -g` on the `tp_osd_tp` threads: the share of
  `PeeringState::prepare_stats_for_publish`.
- Metric: OSD CPU per IOP, `perf stat -e task-clock -p <osd>` divided by IOPS.

## Workload

- fio rbd 4k randread, iodepth 32, on a warm image that fits the BlueStore
  cache. Reads are cheap, so the relative gain is largest here.
- `rados bench -t 64 -b 4096 write`.
- Correctness: the QA workunits that use `flush_pg_stats` must still pass.
