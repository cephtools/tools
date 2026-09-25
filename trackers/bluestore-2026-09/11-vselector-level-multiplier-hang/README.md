# bluestore: max_bytes_for_level_multiplier < 1 hangs OSD mkfs/mount in RocksDBBlueFSVolumeSelector

| | |
|---|---|
| Component | bluestore / bluefs (volume selector), configuration |
| Kind | hang (100% CPU) in OSD mkfs/mount and ceph-bluestore-tool instead of an error |
| Severity | minor |
| Config | RocksDB option `max_bytes_for_level_multiplier < 1` (via `bluestore_rocksdb_options[_annex]`); default policy `bluestore_volume_selection_policy=use_some_extra` with `bluestore_volume_selection_reserved=0`; a dedicated DB device larger than level0 + base (about 2 GiB with defaults: 16M x 64 + 1G) |
| Real-world | **Real tools**: `ceph-osd --mkfs` with the RocksDB option hangs |
| Affected | main. Reproduced on origin/main 8e6a13e7a9a |

## Summary
`RocksDBBlueFSVolumeSelector` is constructed with `rocks_opts.max_bytes_for_level_multiplier`
(a double, BlueStore.cc:7955-7962) and stores it in `uint64_t level_multiplier`
(BlueFS.h:1270). Any value below 1 truncates to 0. `update_from_config()`
(BlueFS.h:1319-1333) then loops
```
do { uint64_t next_level = cur_level * level_multiplier; ... } while (true);
```
Once `cur_level` is 0 the threshold stops growing, and if the DB volume is larger than
it the loop never ends. Non-integer values above 1 are silently truncated as well.
A multiplier below 1 is a nonsensical RocksDB setting; the bug is that it hangs instead
of being rejected.

## Reproduction
`repro.sh`: mkfs with a dedicated 4G DB and
`--bluestore-rocksdb-options-annex=max_bytes_for_level_multiplier=0.5`, with multiplier
10 as the control; each run is killed after 60 s.

## Observed (origin/main 8e6a13e7a9a)
```
== mkfs with dedicated 4G DB, max_bytes_for_level_multiplier=10 (60s timeout)
rc=0 elapsed=3s  (137/killed at 60s = hang)
== mkfs with dedicated 4G DB, max_bytes_for_level_multiplier=0.5 (60s timeout)
rc=137 elapsed=60s  (137/killed at 60s = hang)
```
gdb on the spinning process (run manually):
```
#0  RocksDBBlueFSVolumeSelector::update_from_config (...) at src/os/bluestore/BlueFS.h:1324
#1  BlueStore::_open_bluefs (create=true, read_only=false)
#4  BlueStore::mkfs ()
```

## Suggested fix
Keep the multiplier as a double, validate it (>= 1, and base > 0), and bound the loop.
