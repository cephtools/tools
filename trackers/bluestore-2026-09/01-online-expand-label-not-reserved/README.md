# BlueStore online expand_devices() does not reserve new bdev label locations -> object data and labels overwrite each other

| | |
|---|---|
| Component | bluestore |
| Kind | data corruption / data loss, on-disk format |
| Severity | major (default config: multi-label on, hybrid allocator, NCB) |
| Affected | ceph main @ 98fb1cf8c58 (2026-09-24); online path from 2ab1311f38f (PR #66344, 2026-06) |
| Related | tracker 69997 (squid backport 70298) fixed the same class for the offline/NCB mount path (PR 61843 / 62202, 2025); the online path added later by PR #66344 (2026-06) has the defect again and is not covered by that fix |
| Status | CONFIRMED on c28 2026-09-24 |

## Summary
`ceph tell osd.N bluestore bluefs-bdev-expand` (online, OSD mounted) writes a new
copy of the bdev label at every label position (1G/10G/100G/1000G) that falls into
the grown range and adds it to `bdev_label_valid_locations`, then hands the whole
new range to the allocator with `alloc->init_add_free()`. The label blocks are never
reserved (only `_main_bdev_label_try_reserve()`, called at mount, does that).

Consequences:
1. object data is allocated on the label block and destroys the label copy;
2. any later label rewrite (`write_meta`, e.g. key rotation / require_osd_release,
   another online expand) rewrites 4K of object data at that location -> EIO (csum);
3. with NCB, `_main_bdev_label_remove()` at umount frees the location in the
   allocation file even when an object owns it -> double allocation after restart.

## Root cause
`src/os/bluestore/BlueStore.cc` (98fb1cf8c58):
- 9371-9383: new label positions `[size0, size)` pushed to `bdev_label_valid_locations` and written.
- 9406-9410 (online branch `!need_to_close`): `fm->expand(); alloc->expand(); alloc->init_add_free(aligned_size0, aligned_size - aligned_size0);` — no `init_rm_free` for the label blocks.
- 7020-7066 `_main_bdev_label_try_reserve()` is only reached from `_open_db_and_around()` (offline path).

## Reproduction
`test.cc` -> `MultiLabelTest.OnlineExpandReservesNewLabel` (append to
`src/test/objectstore/store_test.cc`, or apply `../common/patches/`):
900M file-backed store, `truncate` to 3G, `expand_devices()` while mounted, write
400 x 4 MiB objects, check the 1G label, `write_meta()`, remount, read all objects, fsck.

```
ceph_test_objectstore --gtest_filter='*OnlineExpandReservesNewLabel*'
```

## Observed (c28)
```
_read_bdev_label ... data at 0x40000000, unable to decode label
store_test.cc: Failure ... object data overwrote the bdev label at 1G
_main_bdev_label_try_reserve bdev label location 0x40000000 occupied by BlueStore object or BlueFS file, disabling
object OBJ-248 corrupted, read r=-5
fsck error: bdev label at 0x40000000 corrupted
fsck error: oid ...OBJ-248:head#, extent 0x3fff2000~10000 or a subset is already allocated
```

## Expected
Label copy at 1G intact, all objects read back, fsck clean.

## Suggested fix
In the online branch, after `init_add_free()`, reserve every newly added label
location (`alloc->init_rm_free(loc, lsize)`), i.e. run the equivalent of
`_main_bdev_label_try_reserve()` restricted to the new locations.
