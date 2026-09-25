# fsck repair: shared-blob ref_map rebuild keeps only the first valid pextent of each blob

| | |
|---|---|
| Component | bluestore (fsck/repair) |
| Kind | incomplete repair (shared-blob metadata left inconsistent) |
| Severity | minor |
| Config | default; any shared blob (clone/snapshot) with 2 or more valid pextents whose record repair rewrites |
| Affected | main, introduced in a902d22b6c7 (2022). Reproduced on origin/main 8e6a13e7a9a |

## Summary
The second pass of `_fsck_repair_shared_blobs()` (BlueStore.cc:10094-10110) rebuilds
the SharedBlob ref_map but stops after the first valid pextent of each blob:
```
for (auto& p : b.get_extents()) {
  if (p.is_valid()) {
    it->second.get(p.offset, p.length);
    break;                // <-- only the first valid pextent
  }
}
```
fsck counts references for every valid pextent, so repair returns success but writes a
record without references for extents 2..n, and the next fsck again reports mismatching
shared-blob references. A later overwrite or removal of those objects may then hit
`ceph_abort_msg("put on missing extent")` in `bluestore_extent_ref_map_t::put()`
(bluestore_types.cc:259/263); this is not exercised by the repro.

The existing `BluestoreRepairSharedBlobTest` does not catch it because its blobs have a
single pextent.

Minor, same function (10144): `if (cnt >= max_transactions) {}` has an empty body, so
each stray record is removed with its own `submit_transaction_sync` (performance only).

## Reproduction
gtest `StoreTestSpecificAUSize.BluestoreRepairSharedBlobMultiPextent` (`test.cc`): clone
an object whose blob has 2 pextents, inject a wrong shared-blob record, repair, inspect
the ref_map, fsck.

## Observed (origin/main 8e6a13e7a9a)
```
original ref_map(0x432000~1000=2,0x434000~1000=2)
injected ref_map(0x432000~1000=2,0x434000~1000=3)
fsck error:*2 shared blob references aren't matching, at least 2 found
after repair ref_map(0x432000~1000=2)
store_test.cc:12788: Failure
  sb.ref_map.ref_map.size()
    Which is: 1
    Which is: 2
store_test.cc:12792: Failure
  bstore->fsck(false)
    Which is: 2
```

## Expected
After repair the ref_map contains both pextents with 2 references each, and fsck is clean.

## Suggested fix
Remove the `break` in the rebuild loop (it belongs only in the detection pass).
