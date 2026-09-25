// ===== candidate: freelist-blocks-per-key-unvalidated
// ===== candidate: freelist-blocks-per-key-unvalidated
// Add to src/test/objectstore/store_test.cc
//
// bluestore_freelist_blocks_per_key is persisted at mkfs with no validation.
// A multiple-of-8 but non power-of-2 value (96) makes
// BitmapFreelistManager::key_mask = ~(bytes_per_key - 1) a non-contiguous
// mask: keys are not bytes_per_key apart, so a multi-key _xor() trips
// ceph_assert(first_key == last_key) and enumerate_next() reports allocated
// blocks as free.  Bitmap FM is forced with bluestore_allocation_from_file=false.
// Expected (fixed): mkfs rejects the value, or everything below passes.
// Buggy: abort in BitmapFreelistManager::_xor, or fsck errors.
TEST_P(StoreTestSpecificAUSize, FreelistBlocksPerKeyNonPow2) {
  if (string(GetParam()) != "bluestore")
    GTEST_SKIP();
  SetVal(g_conf(), "bluestore_allocation_from_file", "false");
  SetVal(g_conf(), "bluestore_freelist_blocks_per_key", "96");
  g_conf().apply_changes(nullptr);
  StartDeferred(4096);

  coll_t cid;
  auto ch = store->create_new_collection(cid);
  {
    ObjectStore::Transaction t;
    t.create_collection(cid, 0);
    ASSERT_EQ(0, queue_transaction(store, ch, std::move(t)));
  }
  const unsigned N = 16;
  bufferlist big, small;
  big.append(std::string(1 << 20, 'B'));      // 1 MiB -> spans many 384K "keys"
  small.append(std::string(4096, 's'));
  for (unsigned i = 0; i < N; ++i) {
    ObjectStore::Transaction t;
    ghobject_t o(hobject_t(sobject_t("FLBPK_" + stringify(i), CEPH_NOSNAP)));
    t.write(cid, o, 0, (i & 1) ? small.length() : big.length(),
            (i & 1) ? small : big);
    ASSERT_EQ(0, queue_transaction(store, ch, std::move(t)));
  }
  // free some of it again so released ranges cross key boundaries as well
  for (unsigned i = 0; i < N; i += 4) {
    ObjectStore::Transaction t;
    ghobject_t o(hobject_t(sobject_t("FLBPK_" + stringify(i), CEPH_NOSNAP)));
    t.remove(cid, o);
    ASSERT_EQ(0, queue_transaction(store, ch, std::move(t)));
  }
  ch.reset();
  ASSERT_EQ(0, store->umount());
  ASSERT_EQ(0, store->fsck(false)) << "bitmap freelist inconsistent";
  ASSERT_EQ(0, store->mount());
  ch = store->open_collection(cid);
  // allocate again after remount: allocator was loaded from the freelist;
  // phantom-free blocks would be handed out here and overwrite live data.
  for (unsigned i = 0; i < N; i += 4) {
    ObjectStore::Transaction t;
    ghobject_t o(hobject_t(sobject_t("FLBPK_new" + stringify(i), CEPH_NOSNAP)));
    t.write(cid, o, 0, big.length(), big);
    ASSERT_EQ(0, queue_transaction(store, ch, std::move(t)));
  }
  for (unsigned i = 0; i < N; ++i) {
    if (i % 4 == 0) continue;
    ghobject_t o(hobject_t(sobject_t("FLBPK_" + stringify(i), CEPH_NOSNAP)));
    bufferlist got;
    const bufferlist& exp = (i & 1) ? small : big;
    ASSERT_EQ((int)exp.length(), store->read(ch, o, 0, exp.length(), got));
    ASSERT_TRUE(got.contents_equal(exp)) << "object " << i << " overwritten";
  }
  ch.reset();
  ASSERT_EQ(0, store->umount());
  ASSERT_EQ(0, store->fsck(false));
  ASSERT_EQ(0, store->mount());
}
