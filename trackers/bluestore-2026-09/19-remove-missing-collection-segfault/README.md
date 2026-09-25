# _remove_collection dereferences the CollectionRef before its own ENOENT check -> SIGSEGV

| | |
|---|---|
| Component | bluestore |
| Kind | crash |
| Severity | minor (ObjectStore API misuse / replay of a txn removing a missing collection) |
| Affected | ceph main (verified at 8e6a13e7a9a, 2026-09-24; also 98fb1cf8c58) |
| Status | CONFIRMED on clean ceph origin/main 8e6a13e7a9a (2026-09-24, only the test patch applied; see common/verify-origin-main-8e6a13e7a9a.txt); first found on 98fb1cf8c58 |

## Summary
```
int BlueStore::_remove_collection(TransContext *txc, const coll_t &cid, CollectionRef *c)
  (*c)->flush_all_but_last();          // BlueStore.cc:19130 - deref first
  { std::unique_lock l(coll_lock);
    if (!*c) { r = -ENOENT; goto out; } // check comes too late
```
`OP_RMCOLL` for a non-existent collection segfaults instead of returning -ENOENT.

## Reproduction
`test.cc` -> `StoreTest.RemoveMissingCollectionENOENT` (with objectstore_debug_throw_on_failed_txc).

## Observed (c28)
```
bluestore: *** Caught signal (Segmentation fault) **
memstore:  [ OK ]
```

## Suggested fix
Move the `!*c` check before `flush_all_but_last()`.
