# Shared-blob repair re-references only the first valid pextent of each blob

| | |
|---|---|
| Component | bluestore (fsck/repair) |
| Kind | on-disk metadata corruption left by repair; later OSD abort / space release |
| Severity | major |
| Affected | ceph main @ 98fb1cf8c58; regression from a902d22b6c78 (2022) |
| Status | CONFIRMED on c28 2026-09-24 |

## Summary
`_fsck_repair_shared_blobs()` second pass (BlueStore.cc:10094-10110) rebuilds the
SharedBlob ref_map but has a stray `break` after the first valid pextent:
```
for (auto& p : b.get_extents()) {
  if (p.is_valid()) {
    it->second.get(p.offset, p.length);
    break;                // <-- only the first valid pextent
  }
}
```
fsck counts refs for every valid pextent, so repair "succeeds" but the rewritten
record lacks refs for extents 2..n; the next fsck again reports mismatching
shared blob references, and a later overwrite/delete of those objects hits
`put on missing extent` (abort) or releases still-referenced space.
Existing `BluestoreRepairSharedBlobTest` misses it (its blobs have one pextent).
Minor, same function (10144): `if (cnt >= max_transactions) {}` empty body.

## Reproduction
`test.cc` -> `StoreTestSpecificAUSize.BluestoreRepairSharedBlobMultiPextent`:
clone an object whose blob has 2 pextents, inject a broken shared-blob key, repair,
inspect the SharedBlob ref_map, fsck.

## Observed (c28)
```
after repair ref_map(0x432000~1000=2)
sb.ref_map.ref_map.size() Which is: 1, expected 2
bstore->fsck(false) Which is: 2, expected 0
```

## Suggested fix
Drop the `break` in the rebuild loop (keep it only in the detection pass).
