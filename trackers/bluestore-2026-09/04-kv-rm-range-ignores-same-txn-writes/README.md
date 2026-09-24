# RocksDB rm_range_keys() does not see keys written earlier in the same transaction -> omap rmkeyrange/clear/clone/remove leave stale keys

| | |
|---|---|
| Component | bluestore / kv (RocksDBStore) |
| Kind | data corruption (stale / resurrected omap), fsck errors |
| Severity | major |
| Affected | ceph main @ 98fb1cf8c58 |
| Status | CONFIRMED on c28 2026-09-24 (memstore passes the same tests) |

## Summary
`RocksDBStore::RocksDBTransactionImpl::rm_range_keys()` (src/kv/RocksDBStore.cc:1796-1845)
enumerates the keys to delete with a DB iterator over *committed* data
(`db->get_iterator(prefix)`), and only falls back to `DeleteRange` above
`rocksdb_delete_range_threshold` (default 1M). Keys `Put` earlier into the same
WriteBatch are invisible to the iterator and survive. BlueStore relies on it for
`_omap_rmkey_range`, `_do_omap_clear` (omap_clear, remove, clone target reset),
and `_clone` iterates committed omap only as well.

A client op vector like `[omap_set(b), omap_rm_range(a,c)]`, or
`omap_setkeys + omap_clear`, reaches BlueStore as one ObjectStore::Transaction.

## Reproduction
`test.cc` (StoreTest, run for all backends):
- `OmapRmKeyRangeSeesSameTxnKeys`: setkeys(b) + rmkeyrange(a,c) in one txn.
- `OmapClearSeesSameTxnKeys`: setkeys + omap_clear in one txn, then a new omap write.
- `OmapCloneSeesSameTxnKeys`: setkeys on src/dst + clone in one txn.
- `OmapRemoveSeesSameTxnKeys`: setkeys + remove in one txn, then fsck.

## Observed (c28, bluestore; memstore [OK])
```
OmapRmKeyRange: out.count("b") Which is: 1   "key set earlier in the same txn survived rmkeyrange"
OmapClear:      out.count("stale") Which is: 1, h.length() Which is: 12  "cleared omap key/header resurrected"
OmapClone:      out.count("new") 0 "source key set in same txn not cloned"; out.count("junk") 1
OmapRemove:     store->fsck(false) Which is: 1  "stray omap left behind by remove"
```

## Expected
Same results as MemStore: range ops act on the logical state including earlier ops of the txn.

## Suggested fix
In `rm_range_keys()` use a WriteBatchWithIndex-aware iterator, or always emit
`DeleteRange` (plus point deletes) when the batch already contains keys in the
range; in `_clone` include pending batch keys (or flush ordering). Alternatively
track per-txc omap writes in BlueStore and delete them explicitly.
