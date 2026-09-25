# bluestore_freelist_blocks_per_key is not validated: 0 -> SIGFPE, not multiple of 8 -> buffer assert at mkfs

| | |
|---|---|
| Component | bluestore (BitmapFreelistManager), configuration |
| Kind | mkfs crash; value persisted on disk at mkfs |
| Severity | minor |
| Affected | ceph main (verified at 8e6a13e7a9a, 2026-09-24; also 98fb1cf8c58) |
| Status | CONFIRMED on clean ceph origin/main 8e6a13e7a9a (2026-09-24, only the test patch applied; see common/verify-origin-main-8e6a13e7a9a.txt); first found on 98fb1cf8c58 |

## Summary
Used whenever the freelist is "bitmap" (rotational DB, i.e. default HDD OSDs, or
`bluestore_allocation_from_file=false`). `BitmapFreelistManager::create()` persists
the value verbatim (BitmapFreelistManager.cc:76). `_init_misc()` (292-302) builds a
`blocks_per_key >> 3` byte buffer and `key_mask = ~(bytes_per_key - 1)` (valid only
for powers of 2); `size_2_block_count()` (597-602) divides by it.
- 0 -> division by zero (SIGFPE) during mkfs;
- not a multiple of 8 -> `buffer.cc: FAILED ceph_assert(n < _len)`;
- multiple of 8 but not a power of 2 -> non-contiguous key mask (multi-key `_xor`
  asserts / enumerate may report used space as free).

## Reproduction
`repro.sh` (and `test.cc` for 96): mkfs with `--bluestore-allocation-from-file=false
--bluestore-freelist-blocks-per-key={128,0,4,96}` then fsck.

## Observed (c28)
```
blocks_per_key=128: mkfs+fsck clean
blocks_per_key=0:   mkfs CRASHED
blocks_per_key=4:   mkfs CRASHED  buffer.cc: 536: FAILED ceph_assert(n < _len)
blocks_per_key=96:  mkfs+fsck clean (small device; single-key allocations only)
```
`test.cc` -> `StoreTestSpecificAUSize.FreelistBlocksPerKeyNonPow2` (96, 1 MiB writes/removes):
```
BitmapFreelistManager.cc: 577: FAILED ceph_assert(first_key == last_key)
```

## Suggested fix
Validate at mkfs: power of 2, >= 8 (return -EINVAL).
