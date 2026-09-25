# BlueStore bug hunt — 2026-09

20 bugs in BlueStore / BlueFS / ceph-bluestore-tool that occur in real use, found by
code review and reproduced on a clean ceph `origin/main` @ 8e6a13e7a9a (2026-09-24).
Every item was searched on tracker.ceph.com (subject and full text) and on GitHub
ceph/ceph PRs and issues in all states; none is already reported. Each report was
reviewed against the source for accuracy, reachability and severity.

"Real-world" says how each bug was shown outside a unit test:
- **live OSD**: a vstart cluster driven only by real client I/O (rados / librados) and
  real admin commands ([common/live-scenarios.sh](common/live-scenarios.sh),
  [01/live-osd-repro.sh](01-online-expand-label-not-reserved/live-osd-repro.sh));
- **real tools**: `ceph-osd --mkfs`, `ceph-bluestore-tool`, `ceph-kvstore-tool`,
  `ceph-objectstore-tool`, `ceph-conf` on a real OSD directory;
- **store-level**: the real code path, but the precondition can only be created with
  test hooks (repair of an already corrupted store) or observed through ObjectStore.

All gtests and scripts: [common/verify-all.sh](common/verify-all.sh) ->
[common/verify-origin-main-8e6a13e7a9a.txt](common/verify-origin-main-8e6a13e7a9a.txt).
Running and filing: [common/HOWTO.md](common/HOWTO.md).

| # | Bug | Severity | Config | Real-world |
|---|-----|----------|--------|------------|
| 01 | [Online expand leaves new bdev label copies unreserved](01-online-expand-label-not-reserved/) | major | default; online expand (main only) | live OSD: object unfound, HEALTH_ERR |
| 02 | [HybridAllocator online expand after spillover: range free twice](02-hybrid-allocator-expand-double-free/) | major | fragmented OSD + online expand (main only) | live OSD: OSD abort |
| 03 | [write_v2 deferred-reuse race overwrites newer data](03-write-v2-deferred-reuse-race/) | major | write_v2, min_alloc > 4K, HDD | live OSD: object unreadable |
| 04 | [rm_range_keys misses same-batch keys; omap_rmkeyrange leaves stale keys](04-kv-rm-range-ignores-same-txn-writes/) | major | default | live OSD: stale omap key |
| 07 | [misreference repair overwrites false-free in-use blocks](07-repair-misref-into-false-free/) | major | bitmap freelist, corrupted store | store-level |
| 08 | [shared-blob repair keeps only the first pextent](08-repair-shared-blob-first-pextent-only/) | minor | corrupted store | store-level |
| 09 | [undecodable deferred txn passes fsck; repair EIO; OSD cannot mount](09-fsck-ignores-undecodable-deferred/) | major | default | real tools |
| 11 | [max_bytes_for_level_multiplier < 1 hangs mkfs/mount](11-vselector-level-multiplier-hang/) | minor | odd RocksDB option | real tools |
| 12 | [max_blob_size_{hdd,ssd}=0 SIGFPE in write_v2](12-max-blob-size-zero-sigfpe/) | minor | write_v2, dev option | live OSD: OSD SIGFPE |
| 13 | [pool compression_algorithm=none ignored](13-pool-compression-none-ignored/) | minor | pool option | live cluster |
| 14 | [bluestore_min_alloc_size typed uint: 64K = 64000](14-min-alloc-size-uint-units/) | minor | unit suffix | real tools |
| 15 | [small write near 4 GiB wraps fault_range](15-small-write-near-4g-fault-range-wrap/) | minor | osd_max_object_size ~4G | live OSD: OSD abort |
| 16 | [bluefs-import segfaults (*.log, missing dir)](16-bluefs-import-segfault/) | minor | default | real tool |
| 20 | [reshard failure exits 0](20-reshard-failure-exit-zero/) | minor | any | real tool |
| 21 | [fsck_read_bytes_cap=0 makes deep fsck hang](21-fsck-read-bytes-cap-zero-hang/) | minor | option = 0 | real tool |
| 22 | [freelist_blocks_per_key not validated](22-freelist-blocks-per-key-unvalidated/) | minor | dev option | real tools (+ store-level for 96) |
| 23 | [non-power-of-2 BlueFS alloc size aborts](23-bluefs-alloc-size-non-pow2-abort/) | minor | option value | real tool |
| 24 | [bluestore_max_alloc_size and 9 other options have no consumer](24-dead-options-max-alloc-size-ignored/) | minor | any | store-level + static check |
| 25 | [rm_range_keys ignores the range end when iterator bounds are disabled: other objects' omap deleted](25-rm-range-keys-unbounded-without-iterator-bounds/) | major | osd_rocksdb_iterator_bounds_enabled=false (dev) | live OSD: 20 objects' omap wiped |
| 26 | [Snapshot copy-on-write of an Octopus-era per-pool omap object aborts the OSD](26-clone-asserts-on-legacy-per-pool-omap/) | major | OSD created on Octopus, not quick-fixed | live OSD: OSD abort |

`bluestore_write_v2` is off by default; it is randomized only with
`bluestore_write_v2_random=true` (default off) and forced on in some QA objectstore suites.

## Withdrawn
See [withdrawn/README.md](withdrawn/README.md):
- not reachable from a real OSD (ObjectStore API only): 05 rename across hash,
  06 clone_range with shifted offsets, 19 `_remove_collection` null deref;
- not demonstrated in real use: 10 BlueFS envelope ino reuse, 17 revert_wal_to_plain
  on pre-Nautilus OSDs, 18 BlueFS `invalidate_cache`.

## Real-workload round (2026-09-25): examined, not recorded
- `ceph_test_rados` model-checked workload (snapshots, rollback, copy_from, append,
  attrs, omap, watch) + OSD kill -9 thrash on 3-OSD clusters
  ([common/workload-thrash.sh](common/workload-thrash.sh)), variants default, compression
  (lz4, 16K AU), write_v2 + 16K AU, SSD/NCB, SSD + write_v2 + snappy, legacy 64K AU and
  EC k=2 m=1 overwrites: no data mismatch, no OSD assert, deep fsck clean on every OSD.
  The replicated runs hit their time limit early because watch/notify timed out (-110)
  on the slow file-backed test disk (BLUESTORE_SLOW_OP_ALERT); the EC run completed
  5875 ops with 0 errors.
- Not reproduced on a live OSD, dropped: GC rewriting snapshot-shared compressed blobs;
  BlueFS async-discard leak in the NCB allocation file at shutdown (qfsck clean);
  spillover-cleaner migrate vs unlink race (not hit in 5 rounds, cleaner off by default).
- Inconclusive: OSD meta-collection (SnapMapper) omap billed to pool 0 in `ceph df`.
- Crash-consistency review found only the known tracker 68060.

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
