# clone_range with srcoff != dstoff copies the wrong in-flight "writing" buffers to the destination

| | |
|---|---|
| Component | bluestore (buffer cache) |
| Kind | wrong data returned (cache), API contract violation |
| Severity | minor (OSD always uses srcoff == dstoff today) |
| Affected | ceph main @ 98fb1cf8c58; since 6213a94a838 (2022) |
| Status | CONFIRMED on c28 2026-09-24 |

## Summary
`ExtentMap::dup()` / `dup_esb()` (BlueStore.cc:3270, 3399) call
`oldo->bc._dup_writing(txc, newo->c, newo, dstoff, length)`.
`BufferSpace::_dup_writing` (BlueStore.cc:1970-2021) uses that one offset both to
look up source buffers and to place destination buffers. With srcoff != dstoff
it installs source buffers from `[dstoff, dstoff+len)` (unrelated data) into dst
and misses the actually cloned `[srcoff, srcoff+len)`.

## Reproduction
`test.cc` -> `StoreTest.CloneRangeShiftedWithWritingBuffers`: in one txn write src
`[0,128K) = A|B` with FADVISE_WILLNEED, `clone_range(src, dst, 0, 64K, 64K)`; read dst `64K~64K`.

## Observed (c28)
```
bl_eq(a, got) false   "dst[64K,128K) served stale/wrong data from cache"   (returns 'B', expected 'A')
```
After remount the on-disk data is correct.

## Suggested fix
Pass both srcoff and dstoff to `_dup_writing`; scan source at `[srcoff, srcoff+len)`
and place at `b_off - srcoff + dstoff`.
