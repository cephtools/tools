# v1 small write near 4 GiB: uint32 wrap in ExtentMap::fault_range() -> FAILED ceph_assert(last >= start)

| | |
|---|---|
| Component | bluestore |
| Kind | crash (OSD abort, crash loop on replay) |
| Severity | minor (needs osd_max_object_size raised near 4 GiB; _do_gc variant > 2 GiB with compression) |
| Affected | ceph main @ 98fb1cf8c58 |
| Status | CONFIRMED on c28 2026-09-24 |

## Summary
`ExtentMap::fault_range(db, uint32_t offset, uint32_t length)` (BlueStore.cc:4335-4349)
computes `seek_shard(offset + length)` in uint32. `_do_write_small()` (16735-16742)
faults `[offset - max_bsize, offset + max_bsize)`, so for offset > 2^32 - max_bsize the
end wraps and `maybe_load_shard` asserts `last >= start` (4356). `_do_gc()` (18005)
also passes an end as the length (`fault_range(db, *dirty_start, *dirty_end)`),
wrapping once start+end >= 2^32. `_write()` only guarantees offset+length < OBJECT_MAX_SIZE.

## Reproduction
`test.cc` -> `StoreTestSpecificAUSize.SmallWriteNear4GiBShardedOnode`: object with a
sharded extent map (600 x 4K extents), write 0x800 bytes at 0xffffe000.

## Observed (c28)
```
BlueStore.cc: 4356: FAILED ceph_assert(last >= start)
 ... BlueStore::_do_write_small(...) <- _do_write_data <- _do_write
```

## Suggested fix
64-bit range math clamped to OBJECT_MAX_SIZE in fault_range/fault_range_ex; pass a
length (end - start) in `_do_gc`.
