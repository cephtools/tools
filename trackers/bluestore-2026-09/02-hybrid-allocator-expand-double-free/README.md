# HybridAllocator: online expand after bitmap spillover makes the new range free in both tree and bitmap

| | |
|---|---|
| Component | bluestore (allocator) |
| Kind | double-free accounting / allocator assert; possible double allocation |
| Severity | major |
| Config | default `bluestore_allocator=hybrid`, but only after the tree has spilled into the bitmap fallback (range count above `bluestore_hybrid_alloc_mem_cap`, i.e. a heavily fragmented OSD), plus an online expand (main only, PR #66344) |
| Affected | main; online expand path from PR #66344 (2026-06). Reproduced on origin/main 8e6a13e7a9a |

## Summary
Online `bluefs-bdev-expand` calls `alloc->expand(new)` and then
`alloc->init_add_free(old, new - old)` (BlueStore.cc:9408-9410).
`HybridAllocatorBase::expand()` (HybridAllocator.h:60-73) also calls
`bmap_alloc->expand()` when the bitmap fallback exists. `BitmapAllocator::expand()`
(BitmapAllocator.cc:107-121) ends in `AllocatorLevel02::expand()` /
`AllocatorLevel01Loose::expand()` (fastbmap_allocator_impl.h:776-816 / 371-411),
which mark `[old, new)` free in the bitmap by themselves, without updating
`available`. `init_add_free()` then also adds the same range to the AVL/btree2 tree.

The new range is therefore free in both structures. It can be handed out by both the
tree and the bitmap (up to the bitmap's `available`) before the bitmap hits
`ceph_assert(available >= allocated_here)`. The repro demonstrates the double-free
accounting and the assert.

## Reproduction
gtest `HybridAllocator.expand_after_spillover` (`test.cc`, in
`src/test/objectstore/hybrid_allocator_test.cc`; needs the `has_bmap()` accessor added
to `TestHybridAllocator`, included in the patch). The test forces spillover with a
memory cap of `4 * sizeof(range_seg_t)`, then runs the same `expand()` +
`init_add_free()` sequence as `expand_devices()`.
```
unittest_hybrid_allocator --gtest_filter='*expand_after_spillover*'
```

## Observed (origin/main 8e6a13e7a9a)
```
hybrid_allocator_test.cc:329: Failure
Expected equality of these values:
  0u
    Which is: 0
  overlap
    Which is: 268435456
bytes free in both tree and bitmap
fastbmap_allocator_impl.h: 1014: FAILED ceph_assert(available >= allocated_here)
 1: (AllocatorLevel02<AllocatorLevel01Loose>::_allocate_l2(...)
 2: (BitmapAllocator::allocate(...)
 3: (HybridAllocatorBase<AvlAllocator>::allocate(...)
```

## Expected
The 256 MiB of new space is free exactly once; allocation never returns overlapping extents.

## Suggested fix
Keep the fix inside `HybridAllocatorBase::expand()`, e.g. after
`bmap_alloc->expand(new_size)` call `bmap_alloc->init_rm_free(old_size, new_size - old_size)`
so that only `init_add_free()` decides where the new free space goes. (The standalone
BitmapAllocator relies on the expand() + init_add_free() pairing, so changing
`AllocatorLevel02::expand()` itself would break it.)
