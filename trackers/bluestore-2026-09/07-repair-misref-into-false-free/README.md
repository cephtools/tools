# fsck repair of misreferenced extents allocates from the corrupt freelist and overwrites in-use ("false free") blocks

| | |
|---|---|
| Component | bluestore (fsck/repair) |
| Kind | data corruption caused by repair |
| Severity | major (only when repairing a store with both misreferences and false-free ranges; bitmap freelist) |
| Affected | ceph main (verified at 8e6a13e7a9a, 2026-09-24; also 98fb1cf8c58) |
| Status | CONFIRMED on clean ceph origin/main 8e6a13e7a9a (2026-09-24, only the test patch applied; see common/verify-origin-main-8e6a13e7a9a.txt); first found on 98fb1cf8c58 |

## Summary
In `_fsck_on_open`, misreference repair (BlueStore.cc ~11560-11760) runs *before*
"checking freelist vs allocated" (~11918). It allocates replacement space via
`alloc->allocate()` from an allocator initialised from the (corrupt) freelist, so
it can choose blocks that are falsely free but still used by another object, and
`bdev->write()`s the copied blob over that object's data. Afterwards
`fix_false_free()` and the misref txn both `fm->allocate()` the same block;
BitmapFreelistManager is XOR based, so the block ends up marked FREE again.

## Reproduction
`test.cc` -> `StoreTestSpecificAUSize.BluestoreRepairMisrefIntoFalseFree`
(bitmap freelist, avl allocator): object C written first, its AU falsely freed,
plus a misreference between two other objects; run repair; read C; fsck.

## Observed (c28)
```
read C: r Which is: -5 (EIO), expected 65536
out.contents_equal(blC) false   "victim object C was overwritten by repair"
fsck after repair != 0
```

## Suggested fix
Run the freelist-vs-allocated check (and fix false-free in the in-memory
allocator) before misreference repair, or allocate misref replacements from an
allocator built from the fsck `used_blocks` bitmap rather than the freelist.
