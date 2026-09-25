# BlueStore: small write near 4 GiB wraps uint32 in ExtentMap::fault_range() -> FAILED ceph_assert(last >= start)

| | |
|---|---|
| Component | bluestore |
| Kind | crash (ceph_assert); may recur if the client resends the op |
| Severity | minor |
| Config | needs `osd_max_object_size` raised to nearly 4 GiB (BlueStore allows up to OBJECT_MAX_SIZE, BlueStore.cc:8720) and a sharded extent map; default write path (v1) |
| Real-world | **Confirmed on a live OSD**: `osd_max_object_size` raised, librados write at 0xffffe000 -> OSD abort |
| Affected | main. Reproduced on origin/main 8e6a13e7a9a |

## Summary
`ExtentMap::fault_range(db, uint32_t offset, uint32_t length)` (BlueStore.cc:4335-4349)
computes `seek_shard(offset + length)` in uint32. `_do_write_small()` (16734-16742) faults
`[offset - max_bsize, offset + max_bsize)`, so for `offset > 2^32 - max_bsize` the end
wraps and `maybe_load_shard()` hits `ceph_assert(last >= start)` (4356). `_write()` only
guarantees `offset + length < OBJECT_MAX_SIZE`. The assert fires inside `_do_write`,
before the KV commit.

By code inspection (not reproduced): `_do_gc()` (18005) passes an end offset as the length
(`fault_range(db, *dirty_start, *dirty_end)`), which wraps once start + end >= 2^32,
i.e. GC of compressed extents above ~2 GiB.

## Reproduction
gtest `StoreTestSpecificAUSize.SmallWriteNear4GiBShardedOnode` (`test.cc`): build an
object with a sharded extent map (600 x 4K extents), then write 0x800 bytes at 0xffffe000.

## Observed (origin/main 8e6a13e7a9a)
```
src/os/bluestore/BlueStore.cc: 4356: FAILED ceph_assert(last >= start)
*** Caught signal (Aborted) **
 2: (BlueStore::_do_write_small(BlueStore::TransContext*, ...)
 3: (BlueStore::_do_write_data(BlueStore::TransContext*, ...)
 4: (BlueStore::_do_write(BlueStore::TransContext*, ...)
```

## Live OSD reproduction
vstart 1 OSD with `osd_max_object_size = 4294967295`; librados: 600 x 4K writes at 1 MiB + i*8K (sharded extent map), then write 0x800 bytes at 0xffffe000 (`common/live-scenarios.sh 15`).
```
write near 4GiB failed: [errno 110] RADOS timed out (Ioctx.write(p): failed to write big)
OSD DIED:
src/os/bluestore/BlueStore.cc: 4356: FAILED ceph_assert(last >= start)
*** Caught signal (Aborted) **
src/os/bluestore/BlueStore.cc: 4356: FAILED ceph_assert(last >= start)
```

## Suggested fix
Do the range arithmetic in 64 bit and clamp to OBJECT_MAX_SIZE in
`fault_range()` / `fault_range_ex()`; pass a length (end - start) in `_do_gc()`.
