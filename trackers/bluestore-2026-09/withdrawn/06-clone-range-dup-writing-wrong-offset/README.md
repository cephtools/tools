# BlueStore: clone_range with srcoff != dstoff copies the wrong in-flight "writing" buffers to the destination

| | |
|---|---|
| Component | bluestore (buffer cache) |
| Kind | wrong data returned from cache (on-disk data is correct); ObjectStore API contract violation |
| Severity | minor |
| Config | default; needs a buffered write (`FADVISE_WILLNEED` or `bluestore_default_buffered_write=true`) whose `writing` buffers are still present at clone time |
| Affected | main, since 6213a94a838 (2022). Reproduced on origin/main 8e6a13e7a9a |

## Summary
`ExtentMap::dup()` / `dup_esb()` (BlueStore.cc:3270, 3399) call
`oldo->bc._dup_writing(txc, newo->c, newo, dstoff, length)`.
`BufferSpace::_dup_writing()` (BlueStore.cc:1970-2021) uses that one offset both to
look up source buffers and to place destination buffers. With `srcoff != dstoff` it
installs source buffers from `[dstoff, dstoff+len)` (unrelated data) into the
destination and misses the actually cloned range `[srcoff, srcoff+len)`.

The OSD always passes `srcoff == dstoff` (ReplicatedBackend.cc:1901/1968,
PGBackend.cc:869, ECTransaction.cc:957/1110; `PGTransaction::clone_range` has no
callers), so this affects direct ObjectStore users only. The repro also modifies the
source in the same txn, which PGTransaction's ordering rules would not produce.

## Reproduction
gtest `StoreTest.CloneRangeShiftedWithWritingBuffers` (`test.cc`): in one txn write the
source `[0,128K) = A|B` with `FADVISE_WILLNEED`, then `clone_range(src, dst, 0, 64K, 64K)`;
read the destination at `64K~64K`.

## Observed (origin/main 8e6a13e7a9a)
```
store_test.cc:12535: Failure
Value of: bl_eq(a, got)
  Actual: false
Expected: true
dst[64K,128K) served stale/wrong data from cache
```
The read returns `B` (expected `A`); after a remount the on-disk data is correct.

## Suggested fix
Pass both `srcoff` and `dstoff` to `_dup_writing()`: scan the source at
`[srcoff, srcoff+len)` and place buffers at `b_off - srcoff + dstoff`.
