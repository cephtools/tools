// Add to src/test/objectstore/store_test.cc
//
// Pool option compression_algorithm=none must disable compression for that
// pool (pre-a6a499ed5fc behaviour: Compressor::create(cct,"none") == nullptr
// -> no compressor).  Since a6a499ed5fc set_collection_opts() ignores the
// value "none" (leaves c->compression_algorithm unset) and
// _choose_write_options() falls back to the global
// bluestore_compression_algorithm, so data IS compressed.
TEST_P(StoreTestSpecificAUSize, PoolCompressionAlgorithmNoneHonored) {
  if (string(GetParam()) != "bluestore")
    GTEST_SKIP();
  SetVal(g_conf(), "bluestore_write_v2", "false");
  SetVal(g_conf(), "bluestore_compression_mode", "force");
  SetVal(g_conf(), "bluestore_compression_algorithm", "lz4");
  g_conf().apply_changes(nullptr);
  StartDeferred(4096);

  // pool A: no per-pool algorithm (control, must compress with global lz4)
  // pool B: compression_algorithm=none (must NOT compress)
  auto run = [&](int poolid, bool set_none) -> store_statfs_t {
    coll_t cid = coll_t(spg_t(pg_t(0, poolid), shard_id_t::NO_SHARD));
    ghobject_t hoid(hobject_t(sobject_t("CompNone", CEPH_NOSNAP),
                              string(), 0, poolid, string()));
    auto ch = store->create_new_collection(cid);
    {
      ObjectStore::Transaction t;
      t.create_collection(cid, 0);
      EXPECT_EQ(0, queue_transaction(store, ch, std::move(t)));
    }
    if (set_none) {
      pool_opts_t opts;
      opts.set(pool_opts_t::COMPRESSION_ALGORITHM, std::string("none"));
      EXPECT_EQ(0, store->set_collection_opts(ch, opts));
    }
    {
      ObjectStore::Transaction t;
      bufferlist bl;
      bl.append(std::string(0x40000, 'a'));   // highly compressible
      t.write(cid, hoid, 0, bl.length(), bl);
      EXPECT_EQ(0, queue_transaction(store, ch, std::move(t)));
    }
    store_statfs_t st;
    bool per_pool_omap;
    EXPECT_EQ(0, store->pool_statfs(poolid, &st, &per_pool_omap));
    return st;
  };
  store_statfs_t a = run(4373, false);
  store_statfs_t b = run(4374, true);
  cout << "control pool compressed_original=0x" << std::hex
       << a.data_compressed_original << " none-pool compressed_original=0x"
       << b.data_compressed_original << std::dec << std::endl;
  ASSERT_EQ(0x40000, a.data_compressed_original) << "control did not compress; lz4 unavailable?";
  EXPECT_EQ(0, b.data_compressed_original) << "pool compression_algorithm=none ignored";
}
