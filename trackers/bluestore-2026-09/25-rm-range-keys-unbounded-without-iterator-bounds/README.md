# RocksDBStore: with osd_rocksdb_iterator_bounds_enabled=false, rm_range_keys on a sharded column family ignores the range end and deletes other objects' omap

| | |
|---|---|
| Component | bluestore / kv (RocksDBStore) |
| Kind | silent omap data loss across objects (fsck stays clean) |
| Severity | major for affected configs |
| Config | `osd_rocksdb_iterator_bounds_enabled=false` (level dev, default true; added in ca3ccd9559f "to allow rocksdb iterator bounds to be disabled") on a DB with column-family sharding (default `bluestore_rocksdb_cfs`, i.e. every OSD created since Pacific) |
| Real-world | **Confirmed on a live OSD**: one librados `omap_rm_range` on one object deleted that object's keys past the range end and all omap keys of 20 unrelated objects |
| Affected | main, and every release carrying ca3ccd9559f (2022). Reproduced on origin/main 8e6a13e7a9a |

## Summary
`RocksDBStore::RocksDBTransactionImpl::rm_range_keys()` handles sharded prefixes in
its column-family branch (src/kv/RocksDBStore.cc:1835-1861):
```
bounds.lower_bound = start;
bounds.upper_bound = end;
...
auto it = db->new_shard_iterator(cf, prefix, bounds);
for (it->lower_bound(start);
     it->valid() && (--cnt) != 0;      // no "key < end" check
     it->next()) {
  bat.Delete(cf, it->key());
}
```
The loop relies entirely on the iterator's upper bound to stop at `end`. But
`CFIteratorImpl` (2670-2688) only passes the bounds to RocksDB
(`iterate_lower_bound` / `iterate_upper_bound`) when
`osd_rocksdb_iterator_bounds_enabled` is true, and its `valid()` (2725) only checks
`dbiter->Valid()`. With the option off, the loop deletes every key from `start` to the
end of the column-family shard (up to `rocksdb_delete_range_threshold` = 1M keys).
The non-sharded branch (1806-1827) does compare against `end` and is not affected.

BlueStore calls `rm_range_keys()` for `_omap_rmkey_range()` and `_do_omap_clear()`
(omap_clear, removal of an object that has omap, clone-target reset), so any of these
client operations wipes the omap of other objects that sort after it in the same shard
(RGW bucket index shards, CephFS directory fragments, ...). fsck stays clean because
the result is a consistent (but wrong) keyspace.

## Reproduction
`live-osd-repro.sh`: vstart 1 OSD with `osd_rocksdb_iterator_bounds_enabled = false`;
create object `a` with omap keys k00..k09 and 20 objects `victim0..19` with 3 keys each;
one librados write op `remove_omap_range2("k02", "k04")` on `a`; list omap again;
restart the OSD; fsck.

## Observed (origin/main 8e6a13e7a9a, live OSD)
```
a keys before: ['k00', 'k01', 'k02', 'k03', 'k04', 'k05', 'k06', 'k07', 'k08', 'k09']
victim keys before (total): 60
a keys after rm_range [k02,k04): ['k00', 'k01'] (expected k00 k01 k04..k09)
victim keys after (total): 0 (expected 60)
-- restart OSD (pgmeta/pg info may have been wiped as well)
OSD alive after restart
fsck success
```

## Expected
Only `k02` and `k03` of object `a` are removed; the other objects keep their keys.

## Suggested fix
Check the end key in the loop regardless of iterator bounds
(`it->valid() && it->key() < end && --cnt != 0`, using the column family's
comparator), as the non-sharded branch already does.
