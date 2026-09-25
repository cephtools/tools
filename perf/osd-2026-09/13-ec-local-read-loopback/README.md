# EC: the primary's own shard read goes through the messenger

| | |
|---|---|
| Area | EC read path (`ECCommon::ReadPipeline::do_read_op`) |
| Change | small, plus a re-entry fix |
| Expected gain | about 1/k of EC RMW writes and EC reads lose two queue hops |
| Risk | low to medium |
| Status | code analysis, not measured |

## Summary

When an EC op must read the primary's own shard, the classic OSD sends an
`MOSDECSubOpRead` to itself. The local shortcut exists, but only for crimson:

```cpp
#ifdef WITH_CRIMSON // crimson only
    if (pg_shard == get_parent()->whoami_shard()) {
      local_read_op = std::move(read);
      continue;
    }
#endif
```

(`ECCommon.cc:531-536`, and again at 558-566.)

## Theory

The self-message goes through the messenger's single local-delivery thread,
becomes an `OpRequest`, is queued as `immediate`, and a worker takes the PG
lock to run a synchronous `store->read`. The reply makes the same trip back.
That is two extra queue hops, two `OpRequest`s and two PG-lock rounds. EC
writes already apply the local shard with a direct call.

## Proposed change

Enable the local read path in the classic OSD. `ECBackend::handle_sub_read_n_reply`
already exists there (`ECBackend.cc:739`), but the `ECCommon` pure virtual,
its override in `ECBackend.h:87-95` and the `ReadPipeline` forwarder are
`#ifdef WITH_CRIMSON` too (`ECCommon.h:86-92`, `493-499`) and must be enabled
with it. Legacy (non-optimized) pools use
`ECCommonL.cc`, which has no local shortcut at all.

The trap: `ECExtentCache::Object::send_reads` sets `reading = true` only after
`backend_read` returns (`ECExtentCache.cc:106-109`). If the local shard is the
only one read, `read_done()` would now run inside `backend_read`, and then
`reading = true` is set: the object is left marked as reading with no read in
flight. `requesting.clear()` also runs only after `backend_read` returns
(`ECExtentCache.cc:108`), so a new read started from inside the nested
`read_done()` would send the old extents again. Move `requesting` into a local
and set `reading = true` before the call, or defer the local reply with a
queued context.

## Other EC items

- `ECBackend.cc:449`: `pg_missing_tracker_t pmissing = get_local_missing();`
  copies the whole missing set for each sub-write. `get_local_missing()`
  returns a const reference and only `is_missing()` is used: make it
  `const auto&`. The copy is O(missing) during recovery.
- Every EC overwrite does a rollback `clone_range` on each written shard
  (`ECTransaction.cc:1079`), and the generation object is removed later. Its
  cost needs measuring.
- RMW reads and client reads share one completion FIFO
  (`ECCommon.cc:756, 813`), so a slow client read delays RMW reads.
- Legacy (non-optimized) EC pools read and write full stripes and update the
  hinfo attr on all k+m shards. Setting `allow_ec_optimizations` is the largest
  config-only gain for small overwrites.

## How to observe

- `dump_historic_ops` on the primary: `MOSDECSubOpRead` ops whose source is the
  OSD itself.
- For the missing-set copy: `perf record` on `tp_osd_tp` during recovery of an
  EC pool.

## Workload

fio rbd 4k randwrite and randread on an EC data pool (k=4 m=2,
`allow_ec_overwrites`, `allow_ec_optimizations`), iodepth 1 and 32.
