# NCB allocation recovery frees space up to the physical device size, beyond bdev_label.size

| | |
|---|---|
| Component | bluestore (NCB allocation recovery) |
| Kind | space accounting / later expand abort or double allocation |
| Severity | major (grown LV + unclean restart before bluefs-bdev-expand) |
| Affected | ceph main @ 98fb1cf8c58 |
| Status | CONFIRMED on c28 2026-09-24 |

## Summary
`read_allocation_from_drive_on_startup()` sizes its bitmap with the physical
device size: `SimpleBitmap sbmap(cct, bdev->get_size() / min_alloc_size)`
(BlueStore.cc:21259; same in 21415/21474/21488 tool paths) and copies all unused
AUs to the allocator as free. If the backing device was grown but
`bluefs-bdev-expand` has not run yet, an NCB OSD that restarts uncleanly (recovery
path) makes the space beyond `bdev_label.size` allocatable. The next clean umount
persists it in the allocation file; a later expand then calls
`init_add_free(old_size, delta)` over already-free/used space -> AVL overlap
assert, or (if the tail is fully used) silently marks in-use space free.
The bitmap-FM and allocation-file paths are bounded by the label/fm size.

## Reproduction
`test.cc` -> `MultiLabelTest.NcbRecoveryHonorsLabelSize`: 900M store, truncate
the file to 2G, force recovery (`bluestore_debug_inject_allocation_from_file_failure=1`),
mount, check `statfs.available <= 900M`, then offline expand + fsck.

## Observed (c28)
```
Expected: (st.available) <= (old_size), actual: 2120015872 vs 943718400
recovery made space beyond bdev_label.size allocatable
```

## Suggested fix
Size the recovery bitmap by `fm->get_size()` / `p2align(bdev_label.size, min_alloc_size)`.
