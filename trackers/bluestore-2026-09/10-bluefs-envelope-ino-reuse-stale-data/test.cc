// ===== candidate: envmode-ino-reuse-stale-envelopes
// Append to src/test/objectstore/test_bluefs.cc (after the BlueFS_wal fixture).
//
// A WAL that gets a re-issued ino (after compaction + remount) shares the
// envelope stamp with the deleted WAL that used that ino before. After an
// unclean close, replay indexing accepts the old file's envelopes that still
// sit in the (re-allocated) extent as content of the new file.
TEST_F(BlueFS_wal, bughunt_envmode_ino_reuse_stale_envelopes)
{
  SKIP_IF_NO_LIBAIO();
  ConfSaver conf(g_ceph_context->_conf);
  conf.SetVal("bluefs_min_flush_size", "65536");
  conf.SetVal("bluefs_wal_envelope_mode", "true");
  conf.ApplyChanges();

  Create(1048576 * 256, 1048576 * 128, 1048576 * 64);
  ASSERT_EQ(0, fs.mount());

  // "db" -> BDEV_DB; BlueFS log lives on BDEV_WAL, so only our files use DB.
  const std::string dir = "db";
  const std::string old_name = "000001.log";
  const std::string new_name = "000002.log";
  ASSERT_EQ(0, fs.mkdir(dir));

  // head(8) + payload + tail(8) == 4096: every envelope is exactly one block,
  // so flush ends are block aligned and no zero padding hides old envelopes.
  constexpr size_t payload = 4096 - 16;
  constexpr int old_envelopes = 8;
  constexpr int new_envelopes = 2;

  // 1. old WAL, cleanly closed
  BlueFS::FileWriter *w = nullptr;
  ASSERT_EQ(0, fs.open_for_write(dir, old_name, &w, false));
  const uint64_t old_ino = w->file->fnode.ino;
  for (int i = 0; i < old_envelopes; i++) {
    std::string d(payload, 'A');
    fs.append_try_flush(w, d.data(), d.size());
    fs.fsync(w);
  }
  ASSERT_FALSE(w->file->fnode.extents.empty());
  const bluefs_extent_t old_ext = w->file->fnode.extents[0];
  fs.close_writer(w);

  // 2. delete it, compact so its ino disappears from the log, remount
  ASSERT_EQ(0, fs.unlink(dir, old_name));
  fs.sync_metadata(true);
  fs.compact_log();
  fs.umount();
  ASSERT_EQ(0, fs.mount());

  // 3. new WAL: same ino re-issued, write fewer envelopes, then "crash"
  ASSERT_EQ(0, fs.open_for_write(dir, new_name, &w, false));
  const uint64_t new_ino = w->file->fnode.ino;
  for (int i = 0; i < new_envelopes; i++) {
    std::string d(payload, 'B');
    fs.append_try_flush(w, d.data(), d.size());
    fs.fsync(w);
  }
  ASSERT_FALSE(w->file->fnode.extents.empty());
  const bluefs_extent_t new_ext = w->file->fnode.extents[0];
  delete w; // no close_writer(): simulate crash, file stays ENVELOPE (not FIN)
  std::cout << "old ino " << old_ino << " ext " << old_ext
            << " / new ino " << new_ino << " ext " << new_ext << std::endl;
  if (new_ino != old_ino ||
      new_ext.bdev != old_ext.bdev || new_ext.offset != old_ext.offset) {
    fs.umount();
    GTEST_SKIP() << "precondition not met (ino/extent not reused), inconclusive";
  }
  fs.umount();

  // 4. replay + read back
  ASSERT_EQ(0, fs.mount());
  uint64_t size = 0;
  ASSERT_EQ(0, fs.stat(dir, new_name, &size, nullptr));
  BlueFS::FileReader *r = nullptr;
  ASSERT_EQ(0, fs.open_for_read(dir, new_name, &r));
  bufferlist bl;
  fs.read(r, 0, payload * (old_envelopes + 4), &bl, nullptr);
  delete r;
  fs.umount();

  const std::string expected(payload * new_envelopes, 'B');
  std::string got = bl.to_str();
  size_t foreign = std::count(got.begin(), got.end(), 'A');
  std::cout << "stat size " << size << " read " << got.size()
            << " foreign('A') bytes " << foreign << std::endl;
  EXPECT_EQ(expected.size(), size)
    << "stat() of new WAL includes envelopes of the deleted WAL";
  EXPECT_EQ(0u, foreign)
    << "new WAL returns data of a deleted WAL (same ino => same stamp)";
  EXPECT_TRUE(got == expected);
}
