// Variant A: no "db.wal" directory -> silent no-op, file stays ENVELOPE.
TEST_F(BlueFS_wal, bughunt_revert_wal_to_plain_skips_db_dir)
{
  SKIP_IF_NO_LIBAIO();
  ConfSaver conf(g_ceph_context->_conf);
  conf.SetVal("bluefs_min_flush_size", "65536");
  conf.SetVal("bluefs_wal_envelope_mode", "true");
  conf.ApplyChanges();

  Create(1048576 * 256, 1048576 * 128, 1048576 * 64);
  ASSERT_EQ(0, fs.mount());
  bufferlist content;
  many_small_writes("db", "000001.log", content, 20000);
  fs.umount();

  ASSERT_EQ(0, fs.mount());
  fs.revert_wal_to_plain();

  BlueFS::FileReader *reader = nullptr;
  ASSERT_EQ(0, fs.open_for_read("db", "000001.log", &reader));
  bool still_envelope = reader->file->envelope_mode();
  delete reader;
  bufferlist read_content;
  many_small_reads("db", "000001.log", read_content, 20000);
  fs.umount();
  EXPECT_FALSE(still_envelope)
    << "revert_wal_to_plain left an envelope-mode WAL in 'db' untouched";
  EXPECT_EQ(content, read_content);
}

// Variant B: "db.wal" exists too -> ceph_assert(!log.uses_envelope_mode)
// aborts inside revert_wal_to_plain (test binary dies == FAIL).
TEST_F(BlueFS_wal, bughunt_revert_wal_to_plain_asserts_with_db_wal)
{
  SKIP_IF_NO_LIBAIO();
  ConfSaver conf(g_ceph_context->_conf);
  conf.SetVal("bluefs_min_flush_size", "65536");
  conf.SetVal("bluefs_wal_envelope_mode", "true");
  conf.ApplyChanges();

  Create(1048576 * 256, 1048576 * 128, 1048576 * 64);
  ASSERT_EQ(0, fs.mount());
  ASSERT_EQ(0, fs.mkdir("db.wal"));
  bufferlist content_wal, content_db;
  many_small_writes("db.wal", "000002.log", content_wal, 20000);
  many_small_writes("db", "000001.log", content_db, 20000);
  fs.umount();

  ASSERT_EQ(0, fs.mount());
  fs.revert_wal_to_plain(); // buggy: aborts here

  BlueFS::FileReader *reader = nullptr;
  ASSERT_EQ(0, fs.open_for_read("db", "000001.log", &reader));
  EXPECT_FALSE(reader->file->envelope_mode());
  delete reader;
  fs.umount();
}
