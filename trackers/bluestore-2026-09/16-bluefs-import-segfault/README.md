# ceph-bluestore-tool bluefs-import segfaults for *.log targets (envelope mode) and missing dirs

| | |
|---|---|
| Component | ceph-bluestore-tool / bluefs |
| Kind | tool crash |
| Severity | minor |
| Config | default (`bluefs_wal_envelope_mode=true`) |
| Affected | main (envelope mode, v20+). Reproduced on origin/main 8e6a13e7a9a |

## Summary
`bluefs_import()` (src/os/bluestore/bluestore_tool.cc:251-294):
- ignores the return value of `open_for_write()` (278); for a missing directory the
  uninitialized `h` is then used -> SIGSEGV;
- appends with raw `h->append()` (283-289) instead of `append_try_flush()`. With
  envelope mode on (default), any `*.log` file is an ENVELOPE file. `envelope_head_filler`
  is only set up in `append_try_flush()` (BlueFS.cc:4291), so `fsync()` -> `_flush_F()` ->
  `_flush_envelope_F()` writes through an unset filler (BlueFS.cc:4103) -> SIGSEGV;
- by reading (not reproduced): nothing flushes during the import, so an input of 4 GiB or
  more would hit `ceph_assert(l0 + len <= std::numeric_limits<unsigned>::max())` in
  `FileWriter::append()` (BlueFS.h:495).

## Reproduction
`repro.sh`: import a 100 KB file to `db/bughunt.sst` (control), to `db.wal/999999.log`
(envelope), and to `nosuchdir/x`.

## Observed (origin/main 8e6a13e7a9a)
```
== import to db/bughunt.sst (non-envelope, control)
exit=0
== import to db.wal/999999.log (envelope mode)
Segmentation fault      (core dumped) $BT bluefs-import ...
exit=139 (139/134 = crash)
== import to nosuchdir/x
Segmentation fault      (core dumped) $BT bluefs-import ...
exit=139 (expect clean error)
```
Backtrace of the envelope case (from the tool's log file):
```
 2: (BlueFS::_flush_envelope_F(BlueFS::FileWriter*)+0xa7)
 3: (BlueFS::_flush_F(BlueFS::FileWriter*, bool, bool*)+0x1a3)
```

## Suggested fix
Check the `open_for_write()` result; use `append_try_flush()` (or flush periodically);
set up the envelope filler for envelope-mode files, or open imported files in plain mode.
