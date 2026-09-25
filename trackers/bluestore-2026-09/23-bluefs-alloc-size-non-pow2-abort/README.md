# Non power-of-2 bluefs_alloc_size / bluefs_shared_alloc_size accepted, then abort in allocator

| | |
|---|---|
| Component | bluefs, configuration |
| Kind | crash at mkfs / every OSD start after a config change |
| Severity | minor |
| Affected | ceph main (verified at 8e6a13e7a9a, 2026-09-24; also 98fb1cf8c58) |
| Status | CONFIRMED on clean ceph origin/main 8e6a13e7a9a (2026-09-24, only the test patch applied; see common/verify-origin-main-8e6a13e7a9a.txt); first found on 98fb1cf8c58 |

## Summary
`BlueFS::_init_alloc()` (BlueFS.cc:821-858) only checks that
`bluefs_shared_alloc_size` is a multiple of `min_alloc_size` and that
`bluefs_alloc_size` is non-zero. The first BlueFS allocation then passes the unit
to the allocator: `HybridAllocator_impl.h:27 FAILED ceph_assert(std::has_single_bit(unit))`.
The only power-of-2 check is in the admin-socket "bluefs device info" command.

## Reproduction
`repro.sh`: mkfs single device with `--bluefs-shared-alloc-size=96K`; with a dedicated
DB and `--bluefs-alloc-size=1536K`; control with defaults.

## Observed (c28)
```
[control]   mkfs+fsck ok
[shared96K] mkfs CRASHED: HybridAllocator_impl.h: 27: FAILED ceph_assert(std::has_single_bit(unit))
[db1536K]   mkfs CRASHED: HybridAllocator_impl.h: 27: FAILED ceph_assert(std::has_single_bit(unit))
```

## Suggested fix
Validate both options (power of 2, >= min_alloc_size) in `_init_alloc`/mkfs and fail with -EINVAL.
