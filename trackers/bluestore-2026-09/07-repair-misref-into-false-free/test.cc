// Add to src/test/objectstore/store_test.cc (after BluestoreRepairTest)
//
// fsck repair fixes misreferenced extents (BlueStore.cc:~11560-11760) BEFORE it
// checks the freelist ("checking freelist vs allocated", ~11918).  The rewrite
// allocates new space from `alloc`, which was initialised from the (corrupt)
// freelist, so it can pick blocks that are "false free" – i.e. still in use by
// another object – and bdev->write()s the copied blob over that object's data.
// Afterwards fix_false_free() and the misref txn both fm->allocate() the same
// blocks; BitmapFreelistManager is XOR based, so the block ends up FREE again.
//
// Scenario: object C written first (lowest AU), its AU falsely freed, plus a
// misreference between hoid and hoid_dup. After repair C must be intact and
// fsck must be clean.
TEST_P(StoreTestSpecificAUSize, BluestoreRepairMisrefIntoFalseFree) {
  if (string(GetParam()) != "bluestore")
    return;
  const size_t au = 0x10000;

  SetVal(g_conf(), "bluestore_block_db_create", "true");
  SetVal(g_conf(), "bluestore_block_db_size", "4294967296");
  SetVal(g_conf(), "bluestore_allocation_from_file", "false"); // bitmap FM
  SetVal(g_conf(), "bluestore_allocator", "avl");
  SetVal(g_conf(), "bluestore_fsck_on_mount", "false");
  SetVal(g_conf(), "bluestore_fsck_on_umount", "false");
  SetVal(g_conf(), "bluestore_max_blob_size", stringify(au).c_str());

  StartDeferred(au);

  BlueStore* bstore = dynamic_cast<BlueStore*> (store.get());
  ASSERT_FALSE(bstore->has_null_manager());

  const uint64_t pool = 555;
  coll_t cid(spg_t(pg_t(0, pool), shard_id_t::NO_SHARD));
  auto ch = store->create_new_collection(cid);

  ghobject_t hoidC = make_object("Object C (victim)", pool);
  ghobject_t hoid = make_object("Object 1", pool);
  ghobject_t hoid_dup = make_object("Object 1(dup)", pool);
  bufferlist blC, blA, blB;
  blC.append(string(au, 'C'));
  blA.append(string(au, 'A'));
  blB.append(string(au, 'B'));
  int r;
  {
    ObjectStore::Transaction t;
    t.create_collection(cid, 0);
    t.write(cid, hoidC, 0, blC.length(), blC);   // gets the lowest data AU
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  {
    ObjectStore::Transaction t;
    t.write(cid, hoid, 0, blA.length(), blA);
    t.write(cid, hoid_dup, 0, blB.length(), blB);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  ch.reset(nullptr);
  bstore->umount();
  ASSERT_EQ(bstore->fsck(false), 0);
  bstore->mount();
  bstore->inject_false_free(cid, hoidC);
  bstore->inject_misreference(cid, hoid, cid, hoid_dup, 0);
  bstore->umount();

  int errs = bstore->fsck(false);
  cout << "fsck before repair: " << errs << std::endl;
  ASSERT_GT(errs, 0);
  int rr = bstore->repair(false);
  cout << "repair returned: " << rr << std::endl;

  ASSERT_EQ(bstore->mount(), 0);
  ch = store->open_collection(cid);
  {
    bufferlist out;
    r = store->read(ch, hoidC, 0, au, out);
    cout << "read victim C: r=" << r << " first byte="
         << (out.length() ? out.c_str()[0] : '?') << std::endl;
    EXPECT_EQ(r, (int)au);
    EXPECT_TRUE(out.contents_equal(blC)) << "victim object C was overwritten by repair";
  }
  ch.reset(nullptr);
  bstore->umount();
  int errs2 = bstore->fsck(false);
  cout << "fsck after repair: " << errs2 << std::endl;
  EXPECT_EQ(errs2, 0);
  bstore->mount();
}
