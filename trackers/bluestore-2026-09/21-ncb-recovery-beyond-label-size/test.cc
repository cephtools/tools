// ===== candidate: ncb-recovery-beyond-label-size
// ===== candidate: ncb-recovery-beyond-label-size
// Add to src/test/objectstore/store_test.cc inside #ifdef WITH_BLUESTORE,
// next to MultiLabelTest.OnlineExpandReservesNewLabel.
//
// NCB allocation recovery (read_allocation_from_drive_on_startup) sizes its
// bitmap by the PHYSICAL device size.  A grown-but-not-yet-expanded device
// thus gets space beyond bdev_label.size handed to the allocator; a later
// bluefs-bdev-expand then init_add_free()s that range a second time.
TEST_P(MultiLabelTest, NcbRecoveryHonorsLabelSize) {
  static constexpr uint64_t _1M = 1024 * 1024;
  static constexpr uint64_t _1G = 1024 * _1M;
  const uint64_t old_size = 900 * _1M;
  SetVal(g_conf(), "bluestore_block_size", stringify(old_size).c_str());
  SetVal(g_conf(), "bluestore_debug_enforce_settings", "ssd");
  SetVal(g_conf(), "bluestore_allocation_from_file", "true");
  SetVal(g_conf(), "bluestore_debug_inject_allocation_from_file_failure", "0");
  g_conf().apply_changes(nullptr);
  DeferredSetup();
  BlueStore* bstore = dynamic_cast<BlueStore*>(store.get());
  ASSERT_NE(nullptr, bstore);
  ASSERT_TRUE(bstore->has_null_manager());
  string block = get_data_dir() + "/block";
  umount();

  // backing device grows, admin has not run bluefs-bdev-expand yet
  ASSERT_EQ(0, ::truncate(block.c_str(), 2 * _1G));

  // restart after an unclean shutdown -> allocation map recovery from onodes
  SetVal(g_conf(), "bluestore_debug_inject_allocation_from_file_failure", "1");
  g_conf().apply_changes(nullptr);
  ASSERT_EQ(0, mount());
  SetVal(g_conf(), "bluestore_debug_inject_allocation_from_file_failure", "0");
  g_conf().apply_changes(nullptr);

  store_statfs_t st;
  ASSERT_EQ(0, store->statfs(&st));
  cout << "available after recovery: 0x" << std::hex << st.available
       << " label size 0x" << old_size << std::dec << std::endl;
  ASSERT_LE(st.available, old_size)
    << "recovery made space beyond bdev_label.size allocatable";
  umount();   // stores the allocation file

  // now expand offline (ceph-bluestore-tool bluefs-bdev-expand)
  {
    stringstream ss;
    ASSERT_EQ(0, bstore->expand_devices(ss));   // buggy: AVL double-add abort
    cout << ss.str();
  }
  ASSERT_EQ(0, mount());
  ASSERT_EQ(0, store->statfs(&st));
  EXPECT_GT(st.available, old_size);
  EXPECT_LE(st.available, 2 * _1G);
  umount();
  EXPECT_EQ(0, store->fsck(false));
  ASSERT_EQ(0, mount());
}
