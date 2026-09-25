# bluefs_alloc_size / bluefs_shared_alloc_size that are not a power of 2 are accepted, then abort in the allocator

| | |
|---|---|
| Component | bluefs, configuration |
| Kind | crash at mkfs instead of a validation error |
| Severity | minor |
| Config | `bluefs_shared_alloc_size` (single device) or `bluefs_alloc_size` (dedicated DB/WAL) set to a non-power-of-2 value; both options are level advanced (defaults 64K and 1M) |
| Affected | main. Reproduced on origin/main 8e6a13e7a9a |

## Summary
`BlueFS::_init_alloc()` (BlueFS.cc:823-915) only asserts that
`bluefs_shared_alloc_size` is a multiple of `min_alloc_size`
(`ceph_assert(0 == p2phase(shared_alloc_size, unit))`, 841) and that `bluefs_alloc_size`
is non-zero (`ceph_assert(alloc_size[id])`, 873). The first BlueFS allocation then passes
the unit to the allocator, which aborts with
`ceph_assert(std::has_single_bit(unit))` (HybridAllocator_impl.h:27). The only
power-of-2 check is in the admin-socket "bluefs device info" command (BlueFS.cc:141).

By reading (not reproduced): on an existing OSD, the crash happens at the first BlueFS
allocation after the option is changed.

## Reproduction
`repro.sh`: mkfs a single-device OSD with `--bluefs-shared-alloc-size=96K`; mkfs with a
dedicated DB and `--bluefs-alloc-size=1536K`; control with defaults.

## Observed (origin/main 8e6a13e7a9a)
```
== control (defaults)
  [control] mkfs+fsck ok
== single device, bluefs_shared_alloc_size=96K (multiple of 4K min_alloc, not pow2)
  [shared96K] mkfs CRASHED:
    src/os/bluestore/HybridAllocator_impl.h: 27: FAILED ceph_assert(std::has_single_bit(unit))
== dedicated DB, bluefs_alloc_size=1536K
  [db1536K] mkfs CRASHED:
    src/os/bluestore/HybridAllocator_impl.h: 27: FAILED ceph_assert(std::has_single_bit(unit))
```

## Suggested fix
Validate both options in `_init_alloc()` / mkfs (power of 2, >= min_alloc_size) and fail
with -EINVAL.
