// bluestore_max_blob_size{,_hdd,_ssd} accept 0 ("no limit" per the
// option doc), but with bluestore_write_v2=true Writer::_split_data() divides by
// wctx->target_blob_size, which is 0 -> SIGFPE on the first uncompressed write.
TEST_P(StoreTestSpecificAUSize, ZeroMaxBlobSizeWriteV2) {
  if (string(GetParam()) != "bluestore")
    GTEST_SKIP();
  SetVal(g_conf(), "bluestore_write_v2", "true");
  SetVal(g_conf(), "bluestore_max_blob_size", "0");
  SetVal(g_conf(), "bluestore_max_blob_size_hdd", "0");
  SetVal(g_conf(), "bluestore_max_blob_size_ssd", "0");
  SetVal(g_conf(), "bluestore_compression_mode", "none");
  g_conf().apply_changes(nullptr);
  StartDeferred(4096);

  coll_t cid;
  ghobject_t hoid(hobject_t(sobject_t("Object 1", CEPH_NOSNAP)));
  auto ch = store->create_new_collection(cid);
  {
    ObjectStore::Transaction t;
    t.create_collection(cid, 0);
    ASSERT_EQ(0, queue_transaction(store, ch, std::move(t)));
  }
  bufferlist bl;
  bl.append(std::string(65536, 'x'));
  {
    ObjectStore::Transaction t;
    t.write(cid, hoid, 0, bl.length(), bl);
    cout << "writing with max_blob_size=0 and write_v2..." << std::endl;
    ASSERT_EQ(0, queue_transaction(store, ch, std::move(t)));
  }
  bufferlist got;
  ASSERT_EQ(65536, store->read(ch, hoid, 0, 65536, got));
  ASSERT_TRUE(got.contents_equal(bl));
}
