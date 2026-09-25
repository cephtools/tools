# BlueStore: _remove_collection dereferences the CollectionRef before its own ENOENT check

| | |
|---|---|
| Component | bluestore |
| Kind | SIGSEGV instead of a clean error (ObjectStore API misuse) |
| Severity | minor |
| Config | default |
| Affected | main. Reproduced on origin/main 8e6a13e7a9a |

## Summary
```
int BlueStore::_remove_collection(TransContext *txc, const coll_t &cid, CollectionRef *c)
  ...
  (*c)->flush_all_but_last();            // BlueStore.cc:19130, dereference first
  {
    std::unique_lock l(coll_lock);
    if (!*c) { r = -ENOENT; goto out; }  // the check comes too late
```
`OP_RMCOLL` (16288) for a collection that does not exist segfaults instead of returning
-ENOENT. With the default config the OSD aborts either way, because -ENOENT from
OP_RMCOLL ends in `ceph_abort_msg("unexpected error")` (16363-16370); the fix matters for
diagnosability (transaction dump instead of a bare SIGSEGV) and for
`objectstore_debug_throw_on_failed_txc=true` (level dev).

## Reproduction
gtest `StoreTest.RemoveMissingCollectionENOENT` (`test.cc`; sets
`objectstore_debug_throw_on_failed_txc=true` and expects -ENOENT).

## Observed (origin/main 8e6a13e7a9a)
```
*** Caught signal (Segmentation fault) **
 2: (BlueStore::Collection::flush_all_but_last()+0x16)
 3: (BlueStore::_remove_collection(BlueStore::TransContext*, coll_t const&, boost::intrusive_ptr<BlueStore::Collection>*)+0x56)
 4: (BlueStore::_txc_add_transaction(BlueStore::TransContext*, ceph::os::Transaction*)+0x2b5)
```

## Suggested fix
Move the `if (!*c)` check before `(*c)->flush_all_but_last()`.
