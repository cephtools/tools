# RocksDBStore::rm_range_keys() misses keys Put earlier in the same batch; omap_rmkeyrange leaves stale keys

| | |
|---|---|
| Component | bluestore / kv (RocksDBStore) |
| Kind | stale omap data (rmkeyrange: client-reachable); clear/clone/remove variants: ObjectStore API only |
| Severity | major |
| Config | default |
| Real-world | **Confirmed on a live OSD**: one librados write op (`omap_set` + `omap_rm_range`) leaves the key |
| Affected | main. Reproduced on origin/main 8e6a13e7a9a; MemStore passes the same tests |

## Summary
`RocksDBStore::RocksDBTransactionImpl::rm_range_keys()` (src/kv/RocksDBStore.cc:1796-1864)
collects the keys to delete by iterating over *committed* data and only switches to
`DeleteRange` above `rocksdb_delete_range_threshold` (default 1M). Both branches do
this: the plain-prefix branch uses `db->get_iterator(prefix)`, and the column-family
branch (per-pg omap with the default `bluestore_rocksdb_cfs` sharding, `p(3,0-12)`) uses
`new_shard_iterator` (~1835-1861). Keys `Put` earlier into the same WriteBatch are not
visible to the iterator and survive.

BlueStore uses it in `_omap_rmkey_range()` and `_do_omap_clear()` (omap_clear, remove,
clone-target reset); `_clone()` likewise copies only committed omap.

Reachability from the OSD: a librados op that does `OMAPSETVALS` followed by
`OMAPRMKEYRANGE` on the same object reaches BlueStore as one ObjectStore transaction
(`omap_setkeys` + `omap_rmkeyrange`), so the key that was just set survives the range
removal. The clear/remove/clone variants cannot come from the OSD, because
`PGTransaction` discards or reorders those (`omap_clear()` drops earlier updates,
PGTransaction.h:339-346; `remove()` resets the op; clone targets are emitted before
source modifications). They are listed because they break the ObjectStore contract
for direct users.

## Reproduction
StoreTest gtests (`test.cc`, run for every backend):
- `OmapRmKeyRangeSeesSameTxnKeys`: `omap_setkeys(b)` + `omap_rmkeyrange(a, c)` in one txn (client-reachable case).
- `OmapClearSeesSameTxnKeys`: `omap_setkeys` + `omap_clear` in one txn, then a new omap write.
- `OmapCloneSeesSameTxnKeys`: `omap_setkeys` on src and dst + `clone` in one txn.
- `OmapRemoveSeesSameTxnKeys`: `omap_setkeys` + `remove` in one txn, then fsck.

## Observed (origin/main 8e6a13e7a9a; memstore `[ OK ]` for all four)
```
OmapRmKeyRangeSeesSameTxnKeys/1 (bluestore):
  out.count("b")
    Which is: 1
key set earlier in the same txn survived rmkeyrange

OmapClearSeesSameTxnKeys/1:
  out.count("stale")
    Which is: 1
cleared omap key resurrected
  h.length()
    Which is: 12
cleared omap header resurrected

OmapCloneSeesSameTxnKeys/1:
  out.count("new")
    Which is: 0          (source key set in same txn not cloned)
  out.count("junk")
    Which is: 1          (dest key set in same txn not cleared by clone)

OmapRemoveSeesSameTxnKeys/1:
fsck error: found stray (per-pg) omap data on omap_head  key 0x000000000000030C0000000000000000000000012E6B1 0 0
  store->fsck(false)
    Which is: 1
```

## Live OSD reproduction
vstart 1 OSD, default config; librados: set omap `a`,`d`; then ONE write op with `set_omap(b)` + `remove_omap_range2(a, c)`; list omap (`common/live-scenarios.sh 04`).
```
omap keys after op: ['b', 'd'] (expected ['d'])
```

## Expected
Same results as MemStore: range operations act on the logical state, including earlier
operations of the same transaction.

## Suggested fix
In `rm_range_keys()`, also delete keys already Put into the batch within the range
(e.g. use a WriteBatchWithIndex-aware iterator, or always emit `DeleteRange` when the
batch holds keys in the range), and make `_clone()` include pending batch keys.
