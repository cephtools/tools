// Candidate B16: write_v2 may reuse space released in the same txn as a
// *deferred* target and mark the rest of the AU "unused"; a later small write
// into that unused part is issued as direct I/O and can be overwritten by an
// older, still-queued deferred write to the same disk bytes.
static void do_deferred_reuse_race(StoreTestSpecificAUSize* self,
                                   ObjectStore* store,
                                   ObjectStore::CollectionHandle& ch,
                                   const coll_t& cid,
                                   std::function<void()> remount)
{
  ghobject_t hoid(hobject_t(sobject_t("RaceObj", CEPH_NOSNAP)));
  auto fill = [](size_t len, char c) {
    bufferlist bl; bl.append(std::string(len, c)); return bl;
  };
  auto wr = [&](uint64_t off, bufferlist bl) {
    ObjectStore::Transaction t;
    t.write(cid, hoid, off, bl.length(), bl);
    ASSERT_EQ(0, queue_transaction(store, ch, std::move(t)));
  };
  wr(0, fill(16384, 'A'));                 // blob X, one 16K AU
  wr(8192, fill(4096, 'B'));               // deferred overwrite into X
  {
    ObjectStore::Transaction t;
    t.zero(cid, hoid, 4096, 12288);        // X keeps only [0,4K)
    ASSERT_EQ(0, queue_transaction(store, ch, std::move(t)));
  }
  wr(0, fill(4096, 'C'));                  // X's AU released -> reused
  wr(8192, fill(4096, 'D'));               // into unused part of new blob
  bufferlist expected;
  expected.append(fill(4096, 'C'));
  expected.append_zero(4096);
  expected.append(fill(4096, 'D'));
  remount();
  bufferlist got;
  int r = store->read(ch, hoid, 0, 12288, got);
  EXPECT_EQ(12288, r);
  if (r == 12288) {
    EXPECT_TRUE(got.contents_equal(expected)) << "stale data after remount";
    if (!got.contents_equal(expected)) {
      cout << "byte@8K='" << got[8192] << "' (want 'D')" << std::endl;
    }
  }
}

#define DEFERRED_REUSE_SETUP(v2)                                          \
  SetVal(g_conf(), "bluestore_write_v2", (v2) ? "true" : "false");         \
  SetVal(g_conf(), "bluestore_prefer_deferred_size", "65536");            \
  SetVal(g_conf(), "bluestore_deferred_batch_ops", "1000");               \
  SetVal(g_conf(), "bluestore_max_defer_interval", "1000");               \
  SetVal(g_conf(), "bluestore_compression_mode", "none");                 \
  SetVal(g_conf(), "bluestore_debug_randomize_serial_transaction", "0");  \
  g_conf().apply_changes(nullptr);

TEST_P(StoreTestSpecificAUSize, DeferredReuseRaceV1) {
  if (string(GetParam()) != "bluestore")
    GTEST_SKIP();
  DEFERRED_REUSE_SETUP(false);
  StartDeferred(16384);
  coll_t cid;
  auto ch = store->create_new_collection(cid);
  {
    ObjectStore::Transaction t;
    t.create_collection(cid, 0);
    ASSERT_EQ(0, queue_transaction(store, ch, std::move(t)));
  }
  do_deferred_reuse_race(this, store.get(), ch, cid, [&]() {
    ch.reset();
    ASSERT_EQ(0, store->umount());
    ASSERT_EQ(0, store->mount());
    ch = store->open_collection(cid);
  });
}

TEST_P(StoreTestSpecificAUSize, DeferredReuseRaceV2) {
  if (string(GetParam()) != "bluestore")
    GTEST_SKIP();
  DEFERRED_REUSE_SETUP(true);
  StartDeferred(16384);
  coll_t cid;
  auto ch = store->create_new_collection(cid);
  {
    ObjectStore::Transaction t;
    t.create_collection(cid, 0);
    ASSERT_EQ(0, queue_transaction(store, ch, std::move(t)));
  }
  do_deferred_reuse_race(this, store.get(), ch, cid, [&]() {
    ch.reset();
    ASSERT_EQ(0, store->umount());
    ASSERT_EQ(0, store->mount());
    ch = store->open_collection(cid);
  });
}
