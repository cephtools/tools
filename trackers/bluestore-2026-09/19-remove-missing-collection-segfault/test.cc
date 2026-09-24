// ===== candidate: rmcoll-missing-nullderef
// Candidate: BlueStore::_remove_collection dereferences the CollectionRef
// ((*c)->flush_all_but_last()) BEFORE its own "if (!*c) return -ENOENT"
// check, so OP_RMCOLL on a collection that does not exist segfaults instead
// of failing with -ENOENT.
// Paste inside #ifdef WITH_BLUESTORE near the end of store_test.cc.
TEST_P(StoreTest, RemoveMissingCollectionENOENT) {
  if (string(GetParam()) != "bluestore")
    return;
  SetVal(g_conf(), "objectstore_debug_throw_on_failed_txc", "true");
  g_conf().apply_changes(nullptr);
  coll_t cid(spg_t(pg_t(0, 782), shard_id_t::NO_SHARD));
  coll_t missing(spg_t(pg_t(1, 782), shard_id_t::NO_SHARD));
  auto ch = store->create_new_collection(cid);
  int r;
  {
    ObjectStore::Transaction t;
    t.create_collection(cid, 0);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  ASSERT_FALSE(store->collection_exists(missing));
  {
    ObjectStore::Transaction t;
    t.remove_collection(missing);
    int thrown = 0;
    try {
      store->queue_transaction(ch, std::move(t));  // buggy: SIGSEGV here
    } catch (int e) {
      thrown = e;
    }
    EXPECT_EQ(-ENOENT, thrown);
  }
  SetVal(g_conf(), "objectstore_debug_throw_on_failed_txc", "false");
  g_conf().apply_changes(nullptr);
  {
    ObjectStore::Transaction t;
    t.remove_collection(cid);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
}
