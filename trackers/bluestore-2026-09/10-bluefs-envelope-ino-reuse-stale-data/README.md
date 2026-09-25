# BlueFS envelope mode: ino reuse after log compaction lets an unclosed WAL accept a deleted file's envelopes

| | |
|---|---|
| Component | bluefs (WAL envelope mode) |
| Kind | BlueFS returns stale data of a deleted file after an unclean shutdown |
| Severity | minor (no RocksDB-level reproduction yet) |
| Config | default (`bluefs_wal_envelope_mode=true`) |
| Affected | main (envelope mode, v20+). Reproduced on origin/main 8e6a13e7a9a |

## Summary
`_replay()` resets `ino_last = 1` (BlueFS.cc:1445), and the compacted log only records
live files (3084), so after log compaction and a remount, inode numbers of deleted
files are handed out again. An envelope's stamp is `generate_stamp(uuid, ino)`
(BlueFS.h:324); nothing else distinguishes file generations, and `_read_envelope`
checks only the stamp.

Preconditions (all needed):
1. a WAL file is deleted and its ino is reused after compaction and remount;
2. the allocator gives the new file the old file's extent;
3. the new file is not closed cleanly (crash);
4. the new file's last envelope ends exactly where an old envelope starts (a partial
   block is zero-padded and stops the scan; the test uses 4080-byte payloads to get this).

Then envelope scanning in `_envmode_index_file()` (BlueFS.cc:2674-2721) accepts the old
file's leftover envelopes as content of the new file. BlueFS reports a larger size and
returns bytes of the deleted file.

Possible consequence: RocksDB WAL recovery reads stale records. Not demonstrated: the
stale bytes come from a different offset of the old WAL, so RocksDB record framing
would usually fail its CRC and treat them as a torn tail.

## Reproduction
gtest `BlueFS_wal.bughunt_envmode_ino_reuse_stale_envelopes` (`test.cc`, in
`src/test/objectstore/test_bluefs.cc`): write 8 blocks of `A` to a WAL and delete it;
compact; remount; write 2 blocks of `B` to a new WAL; drop the writer without close;
remount; stat and read.

## Observed (origin/main 8e6a13e7a9a)
```
old ino 2 ext 1:0x100000~100000 / new ino 2 ext 1:0x100000~100000
stat size 32640 read 32640 foreign('A') bytes 24480
test_bluefs.cc:3218: Failure
  expected.size()
    Which is: 8160
    Which is: 32640
test_bluefs.cc:3220: Failure
    Which is: 0
    Which is: 24480
```

## Expected
The new WAL's size is 8160 and it contains only `B`.

## Suggested fix
Make the stamp unique per file generation (e.g. mix in a persisted, monotonically
increasing file sequence), or persist `ino_last` across compaction so inodes are not reused.
