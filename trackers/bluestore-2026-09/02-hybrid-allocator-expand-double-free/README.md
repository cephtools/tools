# HybridAllocator::expand() + init_add_free() makes the expanded range free twice (tree and bitmap) -> double allocation

| | |
|---|---|
| Component | bluestore (allocator) |
| Kind | data corruption / crash |
| Severity | major (default `bluestore_allocator=hybrid`) |
| Affected | ceph main (verified at 8e6a13e7a9a, 2026-09-24; also 98fb1cf8c58); online expand path 2ab1311f38f / bd6c72e01da (2026) |
| Status | CONFIRMED on clean ceph origin/main 8e6a13e7a9a (2026-09-24, only the test patch applied; see common/verify-origin-main-8e6a13e7a9a.txt); first found on 98fb1cf8c58 |

## Summary
Online `bluefs-bdev-expand` calls `alloc->expand(new)` and then
`alloc->init_add_free(old, new - old)` (BlueStore.cc:9408-9410).
`HybridAllocatorBase::expand()` (HybridAllocator.h:60-73) also calls
`bmap_alloc->expand()` whenever the bitmap fallback exists (i.e. the tree spilled
over). `AllocatorLevel02::expand()` (fastbmap_allocator_impl.h:371-411, 776-816)
marks `[old,new)` free in the bitmap by itself (without updating `available`), and
`init_add_free()` then adds the same range to the AVL/btree2 tree. The range is
now free in both structures and can be handed out twice.

## Reproduction
`test.cc` -> `HybridAllocator.expand_after_spillover` (append to
`src/test/objectstore/hybrid_allocator_test.cc`; needs accessor
`bool has_bmap() { return get_bmap() != nullptr; }` in `TestHybridAllocator`, included in the patch).
```
unittest_hybrid_allocator --gtest_filter='*expand_after_spillover*'
```

## Observed (c28)
```
Expected equality of these values: 0 / overlap Which is: 268435456
bytes free in both tree and bitmap
fastbmap_allocator_impl.h: 1014: FAILED ceph_assert(available >= allocated_here)
```

## Expected
The new 256 MiB is free exactly once; allocation never returns overlapping extents.

## Suggested fix
Either do not expand the fallback bitmap as "free" (expand it as allocated and let
`init_add_free()` decide where free space goes), or skip `init_add_free()` for the
range already freed by `expand()`; keep `available` consistent.
