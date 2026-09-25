# BlueFS envelope mode: reused inode numbers give a new WAL the same envelope stamp as a deleted one -> stale WAL data accepted on replay

| | |
|---|---|
| Component | bluefs (WAL envelope mode, default on) |
| Kind | data corruption (stale RocksDB WAL records replayed) |
| Severity | major |
| Affected | ceph main (verified at 8e6a13e7a9a, 2026-09-24; also 98fb1cf8c58) |
| Status | CONFIRMED on clean ceph origin/main 8e6a13e7a9a (2026-09-24, only the test patch applied; see common/verify-origin-main-8e6a13e7a9a.txt); first found on 98fb1cf8c58 |

## Summary
`_replay` resets `ino_last = 1` (BlueFS.cc:1445) and the compacted log keeps only
live files (BlueFS.cc:3084), so after compaction + remount deleted inode numbers are
handed out again. The envelope stamp is `generate_stamp(uuid, ino)` (BlueFS.h:324)
— nothing else distinguishes generations. When a new WAL reuses an ino and gets
back the old extent, and is not closed cleanly (OSD crash), envelope scanning in
`_envmode_index_file` (BlueFS.cc:2674-2721) accepts the old WAL's leftover
envelopes as content of the new file; RocksDB then replays records of a deleted WAL.

## Reproduction
`test.cc` -> `BlueFS_wal.bughunt_envmode_ino_reuse_stale_envelopes` (append to
`src/test/objectstore/test_bluefs.cc`): write 8 blocks 'A' to a WAL, delete, compact,
remount, write 2 blocks 'B' to a new WAL, drop the writer without close (crash), remount, stat/read.

## Observed (c28)
```
old ino 2 ext 1:0x100000~100000 / new ino 2 ext 1:0x100000~100000
size Which is: 32640, expected 8160   "stat() of new WAL includes envelopes of the deleted WAL"
Which is: 24480 bytes of 'A'           "new WAL returns data of a deleted WAL (same ino => same stamp)"
```

## Suggested fix
Make the stamp unique per file generation (e.g. include a persisted, monotonically
increasing file sequence / creation seq in the stamp), or persist `ino_last`
across compaction so inodes are never reused.
