# BlueFS::invalidate_cache() aborts on block-aligned offset with unaligned length, and never advances across extents

| | |
|---|---|
| Component | bluefs / BlueRocksEnv |
| Kind | crash |
| Severity | minor (reachable via RocksDB InvalidateCache, e.g. with block_cache_compressed / fadvise paths) |
| Affected | ceph main @ 98fb1cf8c58 |
| Status | CONFIRMED on c28 2026-09-24 |

## Summary
`BlueFS::invalidate_cache()` (BlueFS.cc:2979-3000) rounds the length only when the
offset is unaligned. An aligned offset with an odd length reaches
`KernelDevice::invalidate_cache()` -> `ceph_assert(len % block_size == 0)`
(KernelDevice.cc:1645). The loop also never moves to the next extent, so ranges
spanning extents re-invalidate the first extent only.

## Reproduction
`test.cc` -> `BlueFS.bughunt_invalidate_cache_unaligned_length`: `fs.invalidate_cache(file, 0, 100)`.

## Observed (c28)
```
KernelDevice.cc: 1645: FAILED ceph_assert(len % block_size == 0)
```

## Suggested fix
Always align start down / end up to block size; iterate extents with a correct cursor.
