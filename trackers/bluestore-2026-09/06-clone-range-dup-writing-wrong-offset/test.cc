// ===== candidate: clone-range-dup-writing-offset
// Add to src/test/objectstore/store_test.cc
//
// clone_range(src, dst, srcoff, len, dstoff) with srcoff != dstoff while the
// source still has in-flight ("writing") buffers from the same transaction.
// ExtentMap::dup()/dup_esb() call oldo->bc._dup_writing(..., dstoff, length),
// which scans the SOURCE buffer space at [dstoff, dstoff+len) (instead of
// [srcoff, srcoff+len)) and installs the buffers in the DEST at their source
// offsets.  With buffered writes the bogus buffer becomes CLEAN in dst's
// cache and is served by every later read until eviction/remount.
TEST_P(StoreTest, CloneRangeShiftedWithWritingBuffers) {
  if (string(GetParam()) != "bluestore")
    GTEST_SKIP();
  int r;
  coll_t cid;
  auto ch = store->create_new_collection(cid);
  {
    ObjectStore::Transaction t;
    t.create_collection(cid, 0);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  ghobject_t src(hobject_t(sobject_t("CRsrc", CEPH_NOSNAP)));
  ghobject_t dst(hobject_t(sobject_t("CRdst", CEPH_NOSNAP)));
  src.hobj.pool = -1;
  dst.hobj.pool = -1;

  const unsigned half = 0x10000;
  bufferlist a, b, data;
  a.append(std::string(half, 'A'));
  b.append(std::string(half, 'B'));
  data.append(a);
  data.append(b);
  {
    // One transaction: the src write is still "writing" when clone_range runs.
    ObjectStore::Transaction t;
    t.write(cid, src, 0, data.length(), data,
            CEPH_OSD_OP_FLAG_FADVISE_WILLNEED);
    t.touch(cid, dst);
    // copy src[0, 64K) ('A') to dst[64K, 128K)
    t.clone_range(cid, src, dst, 0, half, half);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  {
    bufferlist got;
    r = store->read(ch, dst, half, half, got);
    ASSERT_EQ((int)half, r);
    // buggy code returns 'B' (src[64K,128K)) from dst's buffer cache
    ASSERT_TRUE(bl_eq(a, got)) << "dst[64K,128K) served stale/wrong data from cache";
  }
  {
    bufferlist got;
    r = store->read(ch, dst, 0, half, got);
    ASSERT_EQ((int)half, r);
    ASSERT_TRUE(got.is_zero());
  }
  // after remount the on-disk mapping is used: correct 'A' either way
  ch.reset();
  ASSERT_EQ(0, store->umount());
  ASSERT_EQ(0, store->mount());
  ch = store->open_collection(cid);
  {
    bufferlist got;
    r = store->read(ch, dst, half, half, got);
    ASSERT_EQ((int)half, r);
    ASSERT_TRUE(bl_eq(a, got));
  }
  {
    ObjectStore::Transaction t;
    t.remove(cid, src);
    t.remove(cid, dst);
    t.remove_collection(cid);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
}
