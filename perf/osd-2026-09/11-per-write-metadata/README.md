# Metadata per small write: dup keys and the full PG info

| | |
|---|---|
| Area | PG log (`PGLog`, `pg_fast_info_t`), BlueStore KV |
| Change | small (fast info); on-disk format change (dups) |
| Expected gain | fewer RocksDB operations and less compaction per write |
| Risk | low (fast info); medium (format change) |
| Status | code analysis, not measured |

## Summary

A small replicated write adds about 7 RocksDB operations on every OSD of the
acting set. When the primary's OSD holds 104 PGs or more, 2 of them are only
for dup tracking.

Per OSD, for a 4 KiB aligned overwrite with NVMe defaults (sizes are
estimates):

```
 puts            onode (+ the "_" and "snapset" attrs)   ~0.5-0.7 KB
                 extent-map shard                        often
                 pg log entry                            ~300 B
                 _fastinfo                               ~220 B
                 dup_ key                                ~116 B   (averaged)
 point deletes   trimmed log key, oldest dup key                  (averaged)
 once per trim batch (~100 writes): the full _info       ~1.2 KB
```

With default settings BlueStore writes no statfs or freelist keys here: the
statfs merge is skipped when `is_statfs_recoverable()` (NCB,
`BlueStore.cc:14607, 14622`).

## Theory

- Trimming is batched: nothing is trimmed until at least
  `osd_pg_log_trim_min` = 100 entries can go (`PeeringState.cc:5128`). But each
  log key is still put once and deleted once, and each dup key too, so the
  number of tombstones per write does not depend on the batch size.
- A trimmed entry becomes a dup if it is within `osd_pg_log_dups_tracked` =
  3000 versions of the head (`PGLog.cc:68`). The per-PG log length L is
  `osd_target_pg_log_entries_per_osd` (300000) divided by the PGs on the
  primary's OSD (the primary computes the trim point, replicas follow it),
  clamped to [250, 10000] (`OSD.cc:9750`). With the `pglog_hardlimit` flag
  (the normal case) the trim keeps the newest L entries
  (`calc_trim_to_aggressive`), so the trimmed entries are at head−L and older.
  - 100 PGs or fewer (L ≥ 3000): no trimmed entry is within 3000 of the
    head, so no dups.
  - 101–103 PGs: part of each trim batch becomes dups (30 of 100 at 101 PGs,
    88 of 100 at 103).
  - 104 PGs or more (L ≤ 2884): the whole trim batch of 100 becomes dup keys,
    one per write on average.
  The autoscaler aims at 100 PGs per OSD (`mon_target_pg_per_osd`), right at
  this line, so whether an OSD pays for dups depends on how many PGs it really
  holds.
- The trim changes `info.log_tail`, which is not in `pg_fast_info_t`
  (`osd_types.h:3216`). So the write that carries a trim encodes and writes the
  full `pg_info_t` instead of `_fastinfo`.

## Proposed change

1. Add `log_tail`, `stats.log_start`, `stats.ondisk_log_start` and
   `stats.log_dups_size` to `pg_fast_info_t` (`osd_types.h:3216`, with a new
   encoding version).
   The trim write then stays on the fast path.
2. Keep trimmed log keys on disk as the dups, instead of writing a separate
   `dup_` key. With 104 PGs or more per OSD this removes 2 of about 7
   KV operations per write, but changes
   the on-disk format: it needs a feature gate and `ceph-objectstore-tool`
   support.
3. Small: the `SnapSet` attr is encoded and set on every head write even when
   unchanged (`PrimaryLogPG.cc:9263`). Skipping it saves CPU and about 50 B per
   `MOSDRepOp`, but no KV key, because the onode is rewritten anyway for the
   `_` attr.

Not recommended: trimming with `omap_rmkeyrange`.
`RocksDBStore::rm_range_keys` iterates the range key by key (below
`rocksdb_delete_range_threshold`), and `BlueStore::_omap_rmkey_range` flushes
the pgmeta onode, both under the PG lock.

## How to observe

- `perf dump`: `osd.osd_pg_info` against `osd.osd_pg_fastinfo`; BlueStore omap
  set/remove counts per `op_w`; RocksDB `submit_latency` and compaction
  counters.
- `debug_bluestore 20`: the keys of one transaction.

## Workload

`rados bench -t 32 -b 4096 write` for at least 10 minutes (so compaction shows
up), rbd 4k randwrite, RGW small-object PUTs, on a cluster with 100–300 PGs
per OSD.
