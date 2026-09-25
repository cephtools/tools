// ===== candidate: bluefs-invalidate-cache-range
// Append to src/test/objectstore/test_bluefs.cc
//
// BlueFS::invalidate_cache() forwards a block-aligned offset with an
// unaligned length to KernelDevice::invalidate_cache(), which asserts
// len % block_size == 0. Buggy build: the test binary aborts (FAIL).
TEST(BlueFS, bughunt_invalidate_cache_unaligned_length)
{
  SKIP_IF_NO_LIBAIO();
  uint64_t size = 1048576 * 128;
  TempBdev bdev{size};
  ConfSaver conf(g_ceph_context->_conf);
  conf.SetVal("bluefs_alloc_size", "65536");   // several extents per file
  conf.ApplyChanges();

  BlueFS fs(g_ceph_context);
  ASSERT_EQ(0, fs.add_block_device(BlueFS::BDEV_DB, bdev.path, false));
  uuid_d fsid;
  ASSERT_EQ(0, fs.mkfs(fsid, { BlueFS::BDEV_DB, false, false }));
  ASSERT_EQ(0, fs.mount());
  ASSERT_EQ(0, fs.mkdir("dir"));

  BlueFS::FileWriter *w = nullptr;
  ASSERT_EQ(0, fs.open_for_write("dir", "file.sst", &w, false));
  std::string data(256 * 1024, 'x');
  fs.append_try_flush(w, data.data(), data.size());
  fs.fsync(w);
  fs.close_writer(w);

  BlueFS::FileReader *r = nullptr;
  ASSERT_EQ(0, fs.open_for_read("dir", "file.sst", &r, true));
  std::cout << "file " << r->file->fnode << std::endl;
  fs.invalidate_cache(r->file, 0, 4096);          // fine
  fs.invalidate_cache(r->file, 4096 + 7, 100);    // fine (offset unaligned -> rounded)
  fs.invalidate_cache(r->file, 0, 100);           // buggy: ceph_assert abort
  fs.invalidate_cache(r->file, 0, 200 * 1024);    // spans extents
  delete r;
  fs.umount();
  SUCCEED();
}
