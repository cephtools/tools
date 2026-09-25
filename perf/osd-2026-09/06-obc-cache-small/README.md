# Object-context cache: 64 entries per PG, and two getattrs per miss

| | |
|---|---|
| Area | PG (`PrimaryLogPG::get_object_context`) |
| Change | config default + small code change |
| Expected gain | CPU per op on RBD-sized working sets; measured about 7.6 µs of OSD CPU per miss avoided (estimate was 3–8 µs) |
| Risk | low (memory is bounded) |
| Status | **confirmed** for the cache size (measured 2026-09-25); the single attr fetch is not measured |

## Summary

The OSD caches an object context (obc: `object_info_t` + `SnapSet`) per
object. The cache holds `osd_pg_object_context_cache_count` = **64** entries
per PG (`common/options/global.yaml.in:3454`). A 100 GiB RBD image over 128
PGs puts about 200 objects in each PG, so uniform random I/O misses the cache
about 70% of the time.

## Theory

A miss, all under the PG lock:

```
 get_object_context                                PrimaryLogPG.cc:12138
   object_contexts.lookup                   miss   12150
   objects_get_attr(OI_ATTR)   BlueStore getattr   12165   get_onode #1
   decode(oi)                                      12193
   lookup_or_create, obs.oi = oi           (copy)  12201-12203
     (cache full: this evicts an entry: release, ssc put, ...)
   get_snapset_context
     objects_get_attr(SS_ATTR) BlueStore getattr           get_onode #2
     decode snapset, insert
   ... then the data read                                  get_onode #3
```

- Each BlueStore `getattr` takes the collection lock and the onode cache-shard
  lock (twice: lookup and unpin).
- The object name of an RBD object is longer than 15 characters, so each
  `hobject_t` copy is a heap allocation.

## Proposed change

1. Raise the default to 256–512. An obc costs about 1.5–2.5 KiB (estimate from
   the struct layouts), so 512 per PG over 100 primary PGs is roughly 100 MiB.
   It is not in a mempool, so `dump_mempools` does not show it. The
   `osd_memory_target` autotuner does count it, because it measures the whole
   heap (`PriorityCache.cc:119-140`): the memory is taken from the BlueStore
   caches, onode cache included. `SharedLRU::set_size()` exists but nothing
   calls it: add a config observer so the size can change at runtime.
2. On a miss in a replicated pool, fetch both attrs with one
   `objects_get_attrs()` call and pass the map to `get_snapset_context`, which
   already takes an `attrs` argument. Keep the `soid.has_snapset()` guard, and
   make its `ceph_assert` on a missing `SS_ATTR` a fallback. It saves a read
   only when the snapset context is not cached yet, and it copies every xattr
   of the object, which costs more for objects with many xattrs (RGW).
3. `obc->obs.oi = std::move(oi)` at `PrimaryLogPG.cc:12203`.

## Measured

Setup: v21.3.0 RelWithDebInfo with `common/measurement-switches.patch`,
vstart, 3 BlueStore OSDs on brd ramdisks (the device is not the bottleneck,
so per-op cost shows up as OSD CPU), 64-CPU host, 3 interleaved rounds, 30 s
per workload (`common/osdperf-leg.sh`).
Values are the mean of 3 runs, with [min..max]. Raw output:
`results/2026-09-25-ab1.txt`.

Workload `orr`: `rados bench rand -t 64` over 16000 objects in a 32-PG pool
(500 objects per PG). The leg changes only
`osd_pg_object_context_cache_count`.

| | 64 (default) | 512 | change |
|---|---|---|---|
| obc hit rate (`object_ctx_cache_hit / total`) | 0.128 | 0.992 | 64/500 predicted 0.128 |
| OSD CPU per read | 61.7 µs [60.5..62.6] | 55.2 µs [53.3..56.5] | −10.6% |
| OSD read latency (`op_r_latency`) | 34.4 µs [33.8..35.2] | 28.1 µs [26.6..29.1] | −18% |
| client IOPS | 62.6k [59.6k..65.0k] | 64.8k [63.8k..65.8k] | +3.5% (ranges overlap) |

- Per miss avoided: 6.56 µs less CPU per read ÷ 0.864 fewer misses per read
  ≈ 7.6 µs of OSD CPU (read latency gives ≈ 7.3 µs).
- With a very large object set (`rr4k`, about 880,000 objects, ~27,000 per
  PG) both sizes miss: predicted hit rates 0.0023 and 0.019, measured 0.002
  and 0.018. There is no gain there, as expected.
- Client IOPS rose less than OSD CPU fell. OSD CPU is not what limits IOPS in
  this setup (the OSD op takes 34 µs of the 1.02 ms client latency); what
  does limit it was not measured.

## How to observe

- For free: `ceph daemon osd.N perf dump` has `osd.object_ctx_cache_hit` and
  `osd.object_ctx_cache_total` (`PrimaryLogPG.cc:12151-12153`).
- bpftrace latency histogram on `PrimaryLogPG::get_object_context`.
- OSD CPU per IOP with the setting at 64 and at 512 (needs an OSD restart
  today).

## Workload

fio rbd 4k randread (and randwrite), iodepth 32, on a warm 100 GiB image over
128 PGs; or `rados bench rand -t 64 -b 4096` after a `seq` warm-up.
