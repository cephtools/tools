# BlueStore bug hunt — 2026-09

23 bugs in BlueStore / BlueFS / ceph-bluestore-tool, each **reproduced** on a clean
ceph `origin/main` @ 8e6a13e7a9a (2026-09-24; only the test patch applied) with the test
or script in its directory — see
[common/verify-origin-main-8e6a13e7a9a.txt](common/verify-origin-main-8e6a13e7a9a.txt),
produced by [common/verify-all.sh](common/verify-all.sh). First found on 98fb1cf8c58.

Every item was searched on tracker.ceph.com (subject and full text) and on GitHub
ceph/ceph PRs and issues in all states (open, merged, closed); none is already reported.
Each report was reviewed against the source for accuracy, reachability and severity.

See [common/HOWTO.md](common/HOWTO.md) to run the reproducers and to file the reports.

| # | Bug | Component | Kind | Severity | Config | Repro |
|---|-----|-----------|------|----------|--------|-------|
| 01 | [Online expand leaves new bdev label copies unreserved](01-online-expand-label-not-reserved/) | bluestore | data corruption | major | default; online expand (main only) | gtest |
| 02 | [HybridAllocator online expand after spillover: range free twice](02-hybrid-allocator-expand-double-free/) | allocator | double free / assert | major | default allocator, fragmented OSD, online expand | gtest |
| 03 | [write_v2 deferred-reuse race overwrites newer data](03-write-v2-deferred-reuse-race/) | bluestore write_v2 | data corruption (csum EIO) | major | write_v2, min_alloc > 4K, HDD | gtest |
| 04 | [rm_range_keys misses same-batch keys; omap_rmkeyrange leaves stale keys](04-kv-rm-range-ignores-same-txn-writes/) | kv / bluestore | stale omap | major | default | gtest |
| 05 | [rename across hash orphans per-pg omap](05-rename-across-hash-loses-omap/) | bluestore | omap loss (API) | minor | default | gtest |
| 06 | [clone_range srcoff != dstoff dups wrong writing buffers](06-clone-range-dup-writing-wrong-offset/) | bluestore cache | wrong data (API) | minor | buffered write | gtest |
| 07 | [misreference repair overwrites false-free in-use blocks](07-repair-misref-into-false-free/) | fsck/repair | corruption by repair | major | bitmap freelist | gtest |
| 08 | [shared-blob repair keeps only the first pextent](08-repair-shared-blob-first-pextent-only/) | fsck/repair | incomplete repair | minor | default | gtest |
| 09 | [undecodable deferred txn passes fsck; repair EIO; OSD cannot mount](09-fsck-ignores-undecodable-deferred/) | fsck | unrecoverable start | major | default | script |
| 10 | [BlueFS envelope ino reuse returns a deleted file's data](10-bluefs-envelope-ino-reuse-stale-data/) | bluefs | stale data after crash | minor | default | gtest |
| 11 | [max_bytes_for_level_multiplier < 1 hangs mkfs/mount](11-vselector-level-multiplier-hang/) | bluefs, config | hang | minor | odd RocksDB option | script |
| 12 | [max_blob_size_{hdd,ssd}=0 SIGFPE in write_v2](12-max-blob-size-zero-sigfpe/) | config | crash | minor | write_v2, dev option | gtest |
| 13 | [pool compression_algorithm=none ignored](13-pool-compression-none-ignored/) | config | setting ignored (regression) | minor | pool option | gtest |
| 14 | [bluestore_min_alloc_size typed uint: 64K = 64000](14-min-alloc-size-uint-units/) | config | mkfs fails | minor | unit suffix | script |
| 15 | [small write near 4 GiB wraps fault_range](15-small-write-near-4g-fault-range-wrap/) | bluestore | crash | minor | osd_max_object_size ~4G | gtest |
| 16 | [bluefs-import segfaults (*.log, missing dir)](16-bluefs-import-segfault/) | tool | crash | minor | default | script |
| 17 | [revert_wal_to_plain ignores envelope WALs in db/](17-revert-wal-to-plain-skips-db-dir/) | bluefs / tool | downgrade ineffective | minor | pre-Nautilus OSDs | gtest |
| 19 | [_remove_collection null deref before ENOENT check](19-remove-missing-collection-segfault/) | bluestore | crash (API misuse) | minor | default | gtest |
| 20 | [reshard failure exits 0](20-reshard-failure-exit-zero/) | tool | wrong exit status | minor | any | script |
| 21 | [fsck_read_bytes_cap=0 makes deep fsck hang](21-fsck-read-bytes-cap-zero-hang/) | fsck, config | hang | minor | option = 0 | script |
| 22 | [freelist_blocks_per_key not validated](22-freelist-blocks-per-key-unvalidated/) | freelist, config | crash / abort | minor | dev option | script + gtest |
| 23 | [non-power-of-2 BlueFS alloc size aborts](23-bluefs-alloc-size-non-pow2-abort/) | bluefs, config | crash | minor | option value | script |
| 24 | [bluestore_max_alloc_size and 9 other options have no consumer](24-dead-options-max-alloc-size-ignored/) | config | option ignored | minor | any | gtest + static |

`bluestore_write_v2` is off by default; it is randomized only with
`bluestore_write_v2_random=true` (default off) and forced on in some QA objectstore suites.

## Withdrawn
- 18 BlueFS `invalidate_cache()` unaligned length: real, but not reachable from the bundled
  RocksDB; see [withdrawn/README.md](withdrawn/README.md).

## Known / not recorded
- Offline expand leaks old end padding with the bitmap freelist: tracker **64567**.
- NCB allocation recovery frees space up to the physical device size (beyond
  `bdev_label.size`): overlaps tracker **75852** / PR 68503 (merged).
- `_deferred_replay` leaves the L key when all extents are eliminated: tracker **68060** (fix reverted).
- Excluded by scope: 79068, 79141, 72848, 80501, EC/repop aligned-txn work.

## Not confirmed (not recorded)
- `BlueFS::device_migrate_to_new` never calls `vselector->add_usage` (BlueFS.cc:2320):
  wrong by reading, but the tool run with `bluefs_check_volume_selector_on_mount=true` did not assert.
- `ceph-bluestore-tool bluefs-export` keeps size/offset in `int` (bluestore_tool.cc:1057):
  a >2 GiB BlueFS file could not be created through `bluefs-import` in reasonable time.
- restore_cfb leaves label copies allocated / loses recovered statfs: the gtests hit
  EOPNOTSUPP from `push_allocation_to_rocksdb()` in the test harness.
- `_set_csum` briefly sets CSUM_NONE on a runtime change (BlueStore.cc:6088): a race, not reproduced.
- write_v2 marks the wrong extent-map shard dirty after lowering the write start: already
  addressed by open PR 70615 ("Fix write v2 compressed write missing dirty_range").
