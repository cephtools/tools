# fsck repair: misreference fix allocates from the corrupt freelist and overwrites false-free in-use blocks

| | |
|---|---|
| Component | bluestore (fsck/repair) |
| Kind | data corruption caused by repair |
| Severity | major (for stores that need this repair) |
| Config | bitmap freelist only (`bluestore_allocation_from_file=false`, rotational DB, or a pre-NCB OSD); with NCB (default on SSD) fsck skips the freelist-vs-allocated check (BlueStore.cc:11919). Requires a store that already has both misreferenced extents and false-free ranges |
| Affected | main. Reproduced on origin/main 8e6a13e7a9a |

## Summary
In `_fsck_on_open()`, misreference repair (starting at BlueStore.cc:11562) runs before
"checking freelist vs allocated" (11921). It gets replacement space with
`alloc->allocate()` (11670) from an allocator that was initialised from the corrupt
freelist, so it can pick blocks that are falsely free but still used by another
object. It then `bdev->write()`s the copied blob there (11704), destroying that
object's data.

Afterwards both repairs mark the same block allocated. The misref txn is not yet
committed when `fm->enumerate_next()` runs, so the block is still reported free and
`fix_false_free()` (11962 -> 20137-20149) allocates it again in a separate txn.
BitmapFreelistManager is XOR-based, so the two `allocate()` calls cancel and the block
ends up marked free again while two objects reference it.

## Reproduction
gtest `StoreTestSpecificAUSize.BluestoreRepairMisrefIntoFalseFree` (`test.cc`; bitmap
freelist, avl allocator so first-fit picks the lowest free AU): object C is written
first and its AU is falsely freed; two other objects get a misreference; run repair;
read C; fsck.

## Observed (origin/main 8e6a13e7a9a)
```
fsck error:  oid #555:68309cac:::Object 1:head#, extent 0x20000~10000 or a subset is already allocated (misreferenced)
fsck error: free extent 0x10000~10000 intersects allocated blocks
fsck error: leaked extent 0x30000~10000
fsck before repair: 3
repair returned: 0
_verify_csum bad crc32c/0x1000 checksum at blob offset 0x0, got 0xfa8dae16, expected 0x4aa38d0b, device location [0x10000~1000], logical extent 0x0~1000, object #555:bc5e31fc:::Object C (victim):head#
store_test.cc:12875: Failure
    Which is: -5
    Which is: 65536
victim object C was overwritten by repair
fsck error:  oid #555:bc5e31fc:::Object C (victim):head#, extent 0x10000~10000 or a subset is already allocated (misreferenced)
fsck error: free extent 0x10000~30000 intersects allocated blocks
fsck after repair: 2
```

## Expected
Repair allocates only truly free space; object C reads back intact; fsck is clean after repair.

## Suggested fix
Fix false-free ranges in the in-memory allocator (run the freelist-vs-allocated check)
before misreference repair, or allocate misreference replacements from an allocator
built from fsck's `used_blocks` bitmap instead of the freelist.
