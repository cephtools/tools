# fsck reports "fsck success" for an undecodable deferred txn, repair cannot remove it, OSD cannot mount

| | |
|---|---|
| Component | bluestore (fsck/repair, deferred replay) |
| Kind | unrecoverable OSD start failure; fsck false negative |
| Severity | major |
| Affected | ceph main @ 98fb1cf8c58 |
| Related | tracker 49847 (field report of the mount failure, closed as HW) |
| Status | CONFIRMED on c28 2026-09-24 |

## Summary
- Regular fsck walks `PREFIX_DEFERRED` ("L") and prints
  `fsck error: failed to decode deferred txn` (BlueStore.cc:11885-11905) but never
  increments the error count -> exit 0 / "fsck success".
- Repair (and deep fsck) first run `_deferred_replay()` during open
  (BlueStore.cc:11156-11164), which fails with -EIO on the same record, so the
  intended "remove undecodable deferred record" repair is unreachable.
- Mount fails with EIO. Result: fsck says healthy, OSD cannot start, repair cannot fix.

## Reproduction
`repro.sh` (uses `../common/common.sh`): mkfs a file-backed OSD, inject a 1-byte value
`ceph-kvstore-tool bluestore-kv <osd> set L zzzz in <file>`, run fsck, repair,
and a `ceph-objectstore-tool --op list` mount.

## Observed (c28)
```
== regular fsck (must NOT report success)
fsck success
fsck rc=0
== repair (should remove the bad record and succeed)
repair failed: (5) Input/output error
repair rc=1
== mount attempt via ceph-objectstore-tool -> abort
BUG: fsck reported the undecodable deferred txn but exited 0 (fsck success)
BUG: repair cannot fix undecodable deferred txn (rc=1)
```

## Suggested fix
Count the decode failure as an error; in repair mode skip/remove undecodable
records in `_deferred_replay()` (or run the removal before replay).
