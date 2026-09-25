// Add to src/test/objectstore/store_test.cc
//
// v1 write path: _do_write_small() faults [offset - max_bsize, offset + max_bsize)
// via ExtentMap::fault_range(uint32 offset, uint32 length).  For a legal write
// close to OBJECT_MAX_SIZE (offset+length < 0xffffffff) offset + max_bsize
// exceeds 2^32; inside fault_range() "offset + length" wraps (uint32) and
// seek_shard(wrapped) returns shard 0 while seek_shard(offset) returns the last
// shard -> maybe_load_shard(): FAILED ceph_assert(last >= start).
TEST_P(StoreTestSpecificAUSize, SmallWriteNear4GiBShardedOnode) {
  if (string(GetParam()) != "bluestore")
    GTEST_SKIP();
  SetVal(g_conf(), "bluestore_write_v2", "false");
  StartDeferred(4096);

  int r;
  coll_t cid;
  ghobject_t hoid(hobject_t(sobject_t("Near4G", CEPH_NOSNAP)));
  hoid.hobj.pool = -1;
  auto ch = store->create_new_collection(cid);
  {
    ObjectStore::Transaction t;
    t.create_collection(cid, 0);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  // Build an extent map large enough to be sharded (> shard_max_size bytes),
  // placed well above 0 so that shard 0 covers [0, ~1MiB) and the shard that
  // covers the top of the object is not shard 0.
  bufferlist bl4k;
  bl4k.append(std::string(0x1000, 'x'));
  for (unsigned batch = 0; batch < 6; ++batch) {
    ObjectStore::Transaction t;
    for (unsigned i = 0; i < 100; ++i) {
      uint64_t off = 0x100000 + (batch * 100 + i) * 0x2000;
      t.write(cid, hoid, off, bl4k.length(), bl4k);
    }
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  // force the onode to be reloaded from disk so shards are really used
  ch.reset();
  ASSERT_EQ(0, store->umount());
  ASSERT_EQ(0, store->mount());
  ch = store->open_collection(cid);
  {
    BlueStore* bstore = dynamic_cast<BlueStore*>(store.get());
    ASSERT_NE(nullptr, bstore);
  }

  // small (< min_alloc_size) write near the 4GiB limit; legal for _write()
  const uint64_t off = 0xffffe000;
  bufferlist small;
  small.append(std::string(0x800, 'y'));
  ASSERT_LT(off + small.length(), 0xffffffffull);
  {
    ObjectStore::Transaction t;
    t.write(cid, hoid, off, small.length(), small);
    r = queue_transaction(store, ch, std::move(t));   // buggy: OSD asserts here
    ASSERT_EQ(r, 0);
  }
  {
    bufferlist got;
    r = store->read(ch, hoid, off, small.length(), got);
    ASSERT_EQ((int)small.length(), r);
    ASSERT_TRUE(bl_eq(small, got));
  }
  {
    ObjectStore::Transaction t;
    t.remove(cid, hoid);
    t.remove_collection(cid);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
}
