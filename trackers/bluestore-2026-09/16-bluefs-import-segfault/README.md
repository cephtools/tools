# ceph-bluestore-tool bluefs-import segfaults for *.log destinations (envelope mode) and for missing directories

| | |
|---|---|
| Component | ceph-bluestore-tool / bluefs |
| Kind | tool crash |
| Severity | minor |
| Affected | ceph main @ 98fb1cf8c58 |
| Status | CONFIRMED on c28 2026-09-24 |

## Summary
`bluefs_import()` (src/os/bluestore/bluestore_tool.cc:274-290):
- ignores the return value of `open_for_write()` -> missing dir: uninitialized `h` used -> SIGSEGV;
- uses raw `h->append()` instead of `append_try_flush()`. With `bluefs_wal_envelope_mode=true`
  (default) any `*.log` file is ENVELOPE; nothing sets `envelope_head_filler`, so
  `fsync()` -> `_flush_F` -> `_flush_envelope_F` writes through a null filler -> SIGSEGV;
- no intermediate flush: inputs >= 4 GiB hit `ceph_assert(l0+len <= UINT_MAX)`.

## Reproduction
`repro.sh`: import 100 KB to `db/bughunt.sst` (control), to `db.wal/999999.log`, and to `nosuchdir/x`.

## Observed (c28)
```
import to db/bughunt.sst               exit=0
import to db.wal/999999.log            Segmentation fault, exit=139
  2: (BlueFS::_flush_envelope_F(BlueFS::FileWriter*)+0xa7)
  3: (BlueFS::_flush_F(BlueFS::FileWriter*, bool, bool*)+0x1a3)
import to nosuchdir/x                  Segmentation fault, exit=139
```

## Suggested fix
Check `open_for_write()`; use `append_try_flush()`/periodic flush; open with
envelope mode disabled (or set up the envelope filler) for imported files.
