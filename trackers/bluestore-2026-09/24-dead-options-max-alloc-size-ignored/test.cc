// ===== candidate: dead-bluestore-options
// ===== candidate: dead-bluestore-options
// Add to src/test/objectstore/store_test.cc (needs `#include <regex>` at top)
//
// bluestore_max_alloc_size ("Maximum size of a single allocation") is read
// into BlueStore::max_alloc_size but that member is never used by any
// allocate() call, so the cap is silently ignored.
TEST_P(StoreTestSpecificAUSize, MaxAllocSizeIgnored) {
  if (string(GetParam()) != "bluestore")
    GTEST_SKIP();
  const uint64_t cap = 0x10000;
  SetVal(g_conf(), "bluestore_max_alloc_size", stringify(cap).c_str());
  SetVal(g_conf(), "bluestore_max_blob_size", "1048576");
  SetVal(g_conf(), "bluestore_compression_mode", "none");
  SetVal(g_conf(), "bluestore_prefer_deferred_size", "0");
  g_conf().apply_changes(nullptr);
  StartDeferred(4096);

  coll_t cid;
  ghobject_t hoid(hobject_t(sobject_t("MaxAllocObj", CEPH_NOSNAP)));
  auto ch = store->create_new_collection(cid);
  {
    ObjectStore::Transaction t;
    t.create_collection(cid, 0);
    ASSERT_EQ(0, queue_transaction(store, ch, std::move(t)));
  }
  bufferlist bl;
  bl.append(std::string(1 << 20, 'm'));
  {
    ObjectStore::Transaction t;
    t.write(cid, hoid, 0, bl.length(), bl);
    ASSERT_EQ(0, queue_transaction(store, ch, std::move(t)));
  }
  JSONFormatter f(false);
  ASSERT_EQ(0, store->dump_onode(ch, hoid, "onode", &f));
  std::ostringstream os;
  f.flush(os);
  std::string js = os.str();
  // physical extents are dumped as {"offset":N,"length":M}
  std::regex re("\\{\"offset\":([0-9]+),\"length\":([0-9]+)\\}");
  uint64_t max_seen = 0, n = 0;
  for (auto it = std::sregex_iterator(js.begin(), js.end(), re);
       it != std::sregex_iterator(); ++it) {
    uint64_t len = std::stoull((*it)[2].str());
    max_seen = std::max(max_seen, len);
    ++n;
  }
  cout << "pextents " << n << " largest 0x" << std::hex << max_seen << std::dec
       << std::endl;
  ASSERT_GT(n, 0u) << js;
  ASSERT_LE(max_seen, cap)
    << "bluestore_max_alloc_size=64K ignored: physical extent of 0x"
    << std::hex << max_seen;
}
