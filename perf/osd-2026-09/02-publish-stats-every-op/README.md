# PG stats are published on every read and every write

| | |
|---|---|
| Area | PG stats (`PG::publish_stats_to_osd`) |
| Change | small |
| Expected gain | CPU on every op; estimated 1–3 µs per op (not measured) |
| Risk | low, if the counters stay exact (see below) |
| Status | code analysis, not measured |

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
