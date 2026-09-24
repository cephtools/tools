# BlueFS::revert_wal_to_plain() only looks at db.wal/: envelope WALs in db/ are left as-is, or it aborts

| | |
|---|---|
| Component | bluefs / ceph-bluestore-tool (revert-wal-to-plain, downgrade-wal-to-v1) |
| Kind | downgrade tool silently ineffective / abort; on-disk format |
| Severity | major for downgrades of OSDs that keep the WAL in db/ |
| Affected | ceph main @ 98fb1cf8c58 |
| Status | CONFIRMED on c28 2026-09-24 |

## Summary
`revert_wal_to_plain()` (BlueFS.cc:2460-2490) hard-codes `"db.wal"`. RocksDB WAL
files live in `db/` for OSDs without a separate WAL dir (e.g. created before
57abe887683). Then:
- no `db.wal` dir: returns 0 ("No files needed to move"), leaving v2/envelope WALs
  in `db/` -> an older Ceph cannot read them after the "successful" revert;
- `db.wal` exists: after conversion `_compact_log_sync_LNF_LD()` keeps
  `log.uses_envelope_mode` (set at mount if any file is envelope, BlueFS.cc:1170-1174;
  compaction resets it only when all files are plain, BlueFS.cc:3128-3134) ->
  `FAILED ceph_assert(!log.uses_envelope_mode)` (2484).

## Reproduction
`test.cc` -> `BlueFS_wal.bughunt_revert_wal_to_plain_skips_db_dir` and
`..._asserts_with_db_wal` (append to `src/test/objectstore/test_bluefs.cc`).

## Observed (c28)
```
still_envelope Actual: true  "revert_wal_to_plain left an envelope-mode WAL in 'db' untouched"
BlueFS.cc: 2484: FAILED ceph_assert(!log.uses_envelope_mode)
```

## Suggested fix
Iterate over all directories (or all envelope-mode files in `nodes.file_map`),
not only `db.wal`.
