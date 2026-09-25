# bluestore_freelist_blocks_per_key is not validated: 0 -> SIGFPE, not multiple of 8 -> assert, non-pow2 -> _xor abort

| | |
|---|---|
| Component | bluestore (BitmapFreelistManager), configuration |
| Kind | mkfs crash (0, not a multiple of 8) / runtime abort (non-power-of-2 multiple of 8); the value is persisted at mkfs |
| Severity | minor |
| Config | `bluestore_freelist_blocks_per_key` (level dev, default 128) set to an invalid value at mkfs; only used with the bitmap freelist (rotational DB, i.e. default HDD OSDs, or `bluestore_allocation_from_file=false`) |
| Real-world | **Real tools**: `ceph-osd --mkfs` crashes (0, 4); the 96 case is shown at the ObjectStore level |
| Affected | main. Reproduced on origin/main 8e6a13e7a9a |

## Summary
`BitmapFreelistManager::create()` reads the option (BitmapFreelistManager.cc:76) and
persists it (101-102) without any check. `_init_misc()` (292-302) builds a
`blocks_per_key >> 3` byte buffer and `key_mask = ~(bytes_per_key - 1)`, which is valid
only for powers of 2; `size_2_block_count()` (597-602) divides by it.
- 0: division by zero (SIGFPE) during mkfs;
- not a multiple of 8 (e.g. 4): `buffer.cc: FAILED ceph_assert(n < _len)` during mkfs;
- a multiple of 8 that is not a power of 2 (e.g. 96): the key mask is not contiguous and
  an allocation spanning keys hits `ceph_assert(first_key == last_key)` in `_xor()` (577).
  By code it could also make `enumerate_next()` report used space as free (not demonstrated).

## Reproduction
- `repro.sh`: mkfs with `--bluestore-allocation-from-file=false
  --bluestore-freelist-blocks-per-key={128,0,4,96}`, then fsck.
- gtest `StoreTestSpecificAUSize.FreelistBlocksPerKeyNonPow2` (`test.cc`): 96, 1 MiB writes and removes.

## Observed (origin/main 8e6a13e7a9a)
```
== blocks_per_key=128 (bitmap freelist: allocation_from_file=false)
  mkfs+fsck clean
== blocks_per_key=0 (bitmap freelist: allocation_from_file=false)
  mkfs CRASHED:
*** Caught signal (Floating point exception) **
== blocks_per_key=4 (bitmap freelist: allocation_from_file=false)
  mkfs CRASHED:
    src/common/buffer.cc: 536: FAILED ceph_assert(n < _len)
== blocks_per_key=96 (bitmap freelist: allocation_from_file=false)
  mkfs+fsck clean        (small device, single-key allocations only)
```
gtest with 96:
```
src/os/bluestore/BitmapFreelistManager.cc: 577: FAILED ceph_assert(first_key == last_key)
 2: (BitmapFreelistManager::allocate(unsigned long, unsigned long, std::shared_ptr<KeyValueDB::TransactionImpl>)+0x81)
 3: (BlueStore::_txc_finalize_kv(BlueStore::TransContext*, std::shared_ptr<KeyValueDB::TransactionImpl>)+0x117)
```

## Suggested fix
Validate at mkfs: power of 2 and >= 8, otherwise fail with -EINVAL.
