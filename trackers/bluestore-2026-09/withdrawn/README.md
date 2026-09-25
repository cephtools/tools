# Withdrawn records (not for filing)

## 18 - BlueFS::invalidate_cache() aborts on a block-aligned offset with an unaligned length
The defect is real (`BlueFS.cc:2979-2999` rounds the length only when the offset is
unaligned, and `KernelDevice::invalidate_cache()` asserts `len % block_size == 0`,
KernelDevice.cc:1645), and the gtest reproduces the abort on origin/main 8e6a13e7a9a.

Withdrawn because no production path reaches it: in the bundled RocksDB (9.11) the only
non-wrapper caller of `InvalidateCache` is `SstFileWriter` with `(0, 0)`, which Ceph
does not use, and length 0 makes the BlueFS loop a no-op (`block_cache_compressed` no
longer exists). Keep it as a possible low-priority cleanup together with:
- the loop never advances to the next extent (only an incomplete fadvise hint);
- in the unaligned-offset branch, the length is not grown by the removed delta;
- RocksDB's contract says length 0 means "to end of file", BlueFS treats it as nothing.

## Not reachable from a real OSD (ObjectStore API only) — withdrawn 2026-09-25
These reproduce with direct ObjectStore calls, but no OSD code path issues them:

- **05 rename across hash orphans per-pg omap**: the OSD only renames temp/recovery
  objects, which keep the target hash (`make_temp_hobject`, hobject.h:308).
- **06 clone_range with srcoff != dstoff**: every OSD caller passes equal offsets
  (ReplicatedBackend.cc:1901/1968, PGBackend.cc:869, ECTransaction.cc:957/1110);
  `PGTransaction::clone_range` has no callers.
- **19 _remove_collection null dereference**: the OSD never removes a collection that
  does not exist, and with the default config a failed OP_RMCOLL aborts either way.
  Worth a two-line PR, not a tracker.

## Not demonstrated in real use — withdrawn 2026-09-25
- **10 BlueFS envelope ino reuse**: needs ino reuse + same extent + unclean shutdown +
  an exact envelope boundary; the RocksDB-level effect is not shown (RocksDB record
  CRCs would most likely reject the stale bytes).
- **17 revert_wal_to_plain skips db/**: only affects OSDs created before Nautilus
  (no `db.wal` directory) that are being downgraded; current mkfs always creates
  `db.wal`, so it could only be shown with a BlueFS-level test, not on a real OSD.
