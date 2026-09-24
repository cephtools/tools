// BUG: online BlueStore::expand_devices() writes a new bdev label copy at every
// label position (1G/10G/100G/1000G) that falls into the grown range, but then
// hands the whole new range to the allocator via init_add_free() without
// reserving the label blocks (only _main_bdev_label_try_reserve() at mount does
// that).  Object data can be allocated on top of the label, and any later
// label rewrite (write_meta, next expand) overwrites object data.
TEST_P(MultiLabelTest, OnlineExpandReservesNewLabel) {
  static constexpr uint64_t _1M = 1024 * 1024;
  static constexpr uint64_t _1G = 1024 * _1M;
  SetVal(g_conf(), "bluestore_block_size", stringify(900 * _1M).c_str());
  SetVal(g_conf(), "bluestore_bdev_label_multi", "true");
  SetVal(g_conf(), "bluestore_debug_inject_allocation_from_file_failure", "0");
  g_conf().apply_changes(nullptr);
  DeferredSetup();
  if (!bdev_supports_label()) {
    GTEST_SKIP();
  }
  BlueStore* bstore = dynamic_cast<BlueStore*>(store.get());
  ASSERT_NE(nullptr, bstore);
  string block = get_data_dir() + "/block";

  // grow the backing file and expand ONLINE (store stays mounted)
  ASSERT_EQ(0, ::truncate(block.c_str(), 3 * _1G));
  {
    stringstream ss;
    ASSERT_EQ(0, bstore->expand_devices(ss));
    cout << ss.str();
  }
  bluestore_bdev_label_t label;
  ASSERT_EQ(0, BlueStore::read_bdev_label_at_pos(g_ceph_context, block, _1G, &label))
    << "expand did not write the label at 1G";

  coll_t cid;
  auto ch = store->create_new_collection(cid);
  {
    ObjectStore::Transaction t;
    t.create_collection(cid, 0);
    ASSERT_EQ(0, queue_transaction(store, ch, std::move(t)));
  }
  // fill ~1.6G so that the region around 1G gets allocated
  const int nobj = 400;
  const uint64_t osize = 4 * _1M;
  auto make_bl = [&](int i) {
    bufferlist bl;
    bl.append(std::string(osize, char('A' + (i % 26))));
    return bl;
  };
  for (int i = 0; i < nobj; i++) {
    ObjectStore::Transaction t;
    ghobject_t hoid(hobject_t(sobject_t("OBJ-" + stringify(i), CEPH_NOSNAP)));
    t.write(cid, hoid, 0, osize, make_bl(i));
    ASSERT_EQ(0, queue_transaction(store, ch, std::move(t)));
  }
  // (a) object data must not have been placed over the label
  EXPECT_EQ(0, BlueStore::read_bdev_label_at_pos(g_ceph_context, block, _1G, &label))
    << "object data overwrote the bdev label at 1G";

  // (b) rewriting labels must not clobber object data
  ASSERT_EQ(0, bstore->write_meta("bughunt_key", "bughunt_value"));

  ch.reset();
  umount();          // NCB: _main_bdev_label_remove() + allocation file
  ASSERT_EQ(0, mount()) << "mount failed after online expand";
  ch = store->open_collection(cid);
  int bad = 0;
  for (int i = 0; i < nobj; i++) {
    ghobject_t hoid(hobject_t(sobject_t("OBJ-" + stringify(i), CEPH_NOSNAP)));
    bufferlist got;
    int r = store->read(ch, hoid, 0, osize, got);
    if (r != (int)osize || !got.contents_equal(make_bl(i))) {
      cout << "object OBJ-" << i << " corrupted, read r=" << r << std::endl;
      ++bad;
    }
  }
  EXPECT_EQ(0, bad) << "objects corrupted by label write";
  ch.reset();
  umount();
  EXPECT_EQ(0, store->fsck(false));
  ASSERT_EQ(0, mount());
}
