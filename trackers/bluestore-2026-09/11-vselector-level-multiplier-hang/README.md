# RocksDBBlueFSVolumeSelector truncates max_bytes_for_level_multiplier to integer -> infinite loop at mkfs/mount

| | |
|---|---|
| Component | bluestore / bluefs (volume selector), configuration |
| Kind | hang (100% CPU) on OSD mkfs/mount/ceph-bluestore-tool |
| Severity | major for affected configs |
| Affected | ceph main @ 98fb1cf8c58 |
| Status | CONFIRMED on c28 2026-09-24 |

## Summary
`RocksDBBlueFSVolumeSelector` stores `rocks_opts.max_bytes_for_level_multiplier`
(double) in `uint64_t level_multiplier` (BlueStore.cc:7955-7962 -> BlueFS.h).
Any value < 1 (e.g. 0.5) becomes 0. `update_from_config()` (BlueFS.h:1300-1335,
default policy `use_some_extra`, `bluestore_volume_selection_reserved=0`) loops
`do { next_level = cur_level * level_multiplier; ... } while(true)`; once
`cur_level` is 0 the threshold stops growing and the loop never ends when the DB
volume is larger than level0+base. (Non-integer values >1 are silently truncated too.)

## Reproduction
`repro.sh`: mkfs with a dedicated 4G DB and
`--bluestore-rocksdb-options-annex=max_bytes_for_level_multiplier=0.5`
(control run with 10).

## Observed (c28)
```
max_bytes_for_level_multiplier=10  rc=0 elapsed=28s
max_bytes_for_level_multiplier=0.5 rc=137 elapsed=60s (killed)
gdb: #0 RocksDBBlueFSVolumeSelector::update_from_config (...) at BlueFS.h:1324
     #1 BlueStore::_open_bluefs ... #4 BlueStore::mkfs
```

## Suggested fix
Keep the multiplier as double; clamp/validate (`>= 1`, base > 0) and bound the loop.
