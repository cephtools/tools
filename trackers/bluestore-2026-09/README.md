# BlueStore bug hunt — 2026-09

25 bugs in BlueStore / BlueFS / ceph-bluestore-tool, each **reproduced** on ceph
`main` @ 98fb1cf8c58 (2026-09-24) with the test or script in its directory.
Every item was searched on tracker.ceph.com (subject keywords) and against open
PRs; none is already reported. Known issues found during the hunt are listed at
the bottom and are NOT recorded as bugs.

See [common/HOWTO.md](common/HOWTO.md) for how to run the reproducers.

| # | Bug | Component | Kind | Severity | Repro |
|---|-----|-----------|------|----------|-------|
| 01 | [Online expand does not reserve new bdev label locations](01-online-expand-label-not-reserved/) | bluestore | data loss, on-disk | major | gtest |
| 02 | [Hybrid allocator expand frees new range twice](02-hybrid-allocator-expand-double-free/) | allocator | corruption / crash | major | gtest |
| 03 | [write_v2 deferred-reuse race overwrites new data](03-write-v2-deferred-reuse-race/) | bluestore write_v2 | corruption (EIO) | major* | gtest |
| 04 | [rm_range_keys ignores same-txn writes (omap rmkeyrange/clear/clone/remove)](04-kv-rm-range-ignores-same-txn-writes/) | kv / bluestore | corruption (stale omap) | major | gtest |
| 05 | [rename across hash orphans per-pg omap](05-rename-across-hash-loses-omap/) | bluestore | omap loss | minor | gtest |
| 06 | [clone_range srcoff!=dstoff dups wrong writing buffers](06-clone-range-dup-writing-wrong-offset/) | bluestore cache | wrong data | minor | gtest |
| 07 | [misref repair overwrites false-free in-use blocks](07-repair-misref-into-false-free/) | fsck/repair | corruption by repair | major | gtest |
| 08 | [shared-blob repair keeps only first pextent](08-repair-shared-blob-first-pextent-only/) | fsck/repair | on-disk metadata | major | gtest |
| 09 | [fsck ignores undecodable deferred txn; repair can't fix; OSD can't mount](09-fsck-ignores-undecodable-deferred/) | fsck | unrecoverable start | major | script |
| 10 | [BlueFS envelope ino reuse accepts stale WAL data](10-bluefs-envelope-ino-reuse-stale-data/) | bluefs | corruption | major | gtest |
| 11 | [volume selector multiplier<1 infinite loop](11-vselector-level-multiplier-hang/) | bluefs, config | hang | major | script |
| 12 | [max_blob_size=0 SIGFPE in write_v2](12-max-blob-size-zero-sigfpe/) | config | crash | minor* | gtest |
| 13 | [pool compression_algorithm=none ignored](13-pool-compression-none-ignored/) | config | config ignored | minor | gtest |
| 14 | [bluestore_min_alloc_size typed uint: 64K=64000](14-min-alloc-size-uint-units/) | config | mkfs failure | minor | script |
| 15 | [small write near 4 GiB wraps fault_range](15-small-write-near-4g-fault-range-wrap/) | bluestore | crash | minor | gtest |
| 16 | [bluefs-import segfaults](16-bluefs-import-segfault/) | tool | crash | minor | script |
| 17 | [revert_wal_to_plain skips db/ (or aborts)](17-revert-wal-to-plain-skips-db-dir/) | bluefs / tool | downgrade broken | major | gtest |
| 18 | [BlueFS invalidate_cache unaligned length abort](18-bluefs-invalidate-cache-unaligned/) | bluefs | crash | minor | gtest |
| 19 | [_remove_collection null deref before ENOENT check](19-remove-missing-collection-segfault/) | bluestore | crash | minor | gtest |
| 20 | [reshard failure exits 0](20-reshard-failure-exit-zero/) | tool | wrong exit code | minor | script |
| 21 | [NCB recovery frees space beyond bdev_label.size](21-ncb-recovery-beyond-label-size/) | NCB | space accounting | major | gtest |
| 22 | [fsck_read_bytes_cap=0 deep fsck hang](22-fsck-read-bytes-cap-zero-hang/) | fsck, config | hang | minor | script |
| 23 | [freelist_blocks_per_key unvalidated](23-freelist-blocks-per-key-unvalidated/) | freelist, config | crash / broken freelist | minor | script + gtest |
| 24 | [non-pow2 bluefs alloc size aborts](24-bluefs-alloc-size-non-pow2-abort/) | bluefs, config | crash | minor | script |
| 25 | [bluestore_max_alloc_size & other options ignored](25-dead-options-max-alloc-size-ignored/) | config | config ignored | minor | gtest + static |

\* `bluestore_write_v2` is off by default (randomized in debug builds).

## Known / not recorded
- Offline expand leaks old end padding with the bitmap freelist: already tracker **64567**.
- `_deferred_replay` leaves the L key when all extents are eliminated: tracker **68060** (fix reverted).
- Excluded by scope: 79068, 79141, 72848, 80501, EC/repop aligned-txn work.

## Not confirmed (not recorded)
- `BlueFS::device_migrate_to_new` never calls `vselector->add_usage` (BlueFS.cc:2320):
  wrong by reading, but the tool run with `bluefs_check_volume_selector_on_mount=true` did not assert.
- `ceph-bluestore-tool bluefs-export` keeps size/offset in `int` (bluestore_tool.cc:1057):
  a >2 GiB BlueFS file could not be created through `bluefs-import` in reasonable time.
- restore_cfb leaves label copies allocated / loses recovered statfs:
  the gtests hit EOPNOTSUPP from `push_allocation_to_rocksdb()` in the test harness.
- `_set_csum` briefly sets CSUM_NONE on runtime change (BlueStore.cc:6088): race, not reproduced.
- write_v2 marks the wrong extent-map shard dirty after lowering the write start: not yet tested.
