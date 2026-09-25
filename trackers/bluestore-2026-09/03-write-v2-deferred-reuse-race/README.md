# write_v2: released AU reused in the same txn as deferred target, later direct write into its "unused" part is overwritten by an older queued deferred write

| | |
|---|---|
| Component | bluestore (write_v2 / Writer) |
| Kind | silent data corruption (EIO on read) |
| Severity | major for `bluestore_write_v2=true` (non-default; randomized in debug builds) |
| Affected | ceph main (verified at 8e6a13e7a9a, 2026-09-24; also 98fb1cf8c58) |
| Status | CONFIRMED on clean ceph origin/main 8e6a13e7a9a (2026-09-24, only the test patch applied; see common/verify-origin-main-8e6a13e7a9a.txt); first found on 98fb1cf8c58 |

## Summary
`Writer::_defer_or_allocate()` (Writer.cc:1311-1335) reuses space released
*in the same transaction* (`released`) as the target of a deferred write, and the
new blob marks the rest of the AU unused (`add_unused_all()`, Writer.cc:513).
A later small write into that unused part is issued as a direct aio write.
An older deferred write to the same disk bytes (from a previous txc, still in the
deferred queue) is applied afterwards and overwrites the new data. v1 avoids this
by releasing space to the allocator only after preceding deferred writes finished
(`_txc_finish`).

## Reproduction
`test.cc` -> `StoreTestSpecificAUSize.DeferredReuseRaceV1` / `V2`
(min_alloc 16K, `bluestore_prefer_deferred_size=65536`, `bluestore_deferred_batch_ops=1000`,
`bluestore_max_defer_interval=1000`):
write 16K A; write 8K~4K B (deferred); zero 4K~12K; write 0~4K C (AU reused deferred);
write 8K~4K D (direct into unused); remount; read 0~12K.

## Observed (c28)
```
_defer_or_allocate released=0x4000 need=0x4000 deferred
_deferred_submit_unlock seq 1 0x436000~1000 crc 9042a7fd      <- old 'B'
_deferred_submit_unlock seq 2 0x434000~1000 crc 4aa38d0b
_verify_csum bad crc32c/0x1000 checksum at blob offset 0x2000, got 0x9042a7fd, expected 0x45dcb42b
V1: [ OK ]   V2: read returns -5 (EIO)
```

## Expected
Read returns `C | zeros | D`.

## Suggested fix
Do not reuse txn-released space when older deferred IO may target it (mirror v1:
release to allocator after the osr's preceding deferred writes complete), or force
subsequent writes into such blobs to be deferred / wait for deferred drain.
