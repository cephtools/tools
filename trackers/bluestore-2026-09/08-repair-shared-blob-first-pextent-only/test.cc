// Add to src/test/objectstore/store_test.cc (after BluestoreRepairSharedBlobTest)
//
// _fsck_repair_shared_blobs() rebuilds the ref_map of a broken shared blob by
// walking all objects, but the 2nd _fsck_foreach_shared_blob() lambda does
//     for (auto& p : b.get_extents()) { if (p.is_valid()) { get(p); break; } }
// i.e. it only references the FIRST valid pextent of every blob
// (BlueStore.cc:10103-10108, regression from a902d22b6c78).  For a shared blob
// with >1 valid pextent the rewritten SharedBlob record lacks the other
// extents: repair reports success, a following fsck still finds ref
// mismatches, and later put_ref() on the missing ranges hits
// "put on missing extent".
//
// Same setup as BluestoreRepairSharedBlobTest but WITHOUT the two zero() ops,
// so both the head and the clone keep a blob with two valid pextents.
TEST_P(StoreTestSpecificAUSize, BluestoreRepairSharedBlobMultiPextent) {
  if (string(GetParam()) != "bluestore")
    return;

  SetVal(g_conf(), "bluestore_fsck_on_mount", "false");
  SetVal(g_conf(), "bluestore_fsck_on_umount", "false");
  SetVal(g_conf(), "bluestore_allocator", "avl");

  const size_t block_size = 0x1000;
  StartDeferred(block_size);

  BlueStore* bstore = dynamic_cast<BlueStore*> (store.get());

  const uint64_t pool = 555;
  coll_t cid(spg_t(pg_t(0, pool), shard_id_t::NO_SHARD));
  auto ch = store->create_new_collection(cid);

  ghobject_t hoid = make_object("Object 1", pool);
  ghobject_t hoid_cloned = hoid;
  hoid_cloned.hobj.snap = 1;
  ghobject_t hoid2 = make_object("Object 2", pool);

  string s(block_size, 1);
  bufferlist bl;
  bl.append(s);
  int r;
  {
    ObjectStore::Transaction t;
    t.create_collection(cid, 0);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  {
    ObjectStore::Transaction t;
    t.write(cid, hoid, 0, bl.length(), bl);
    t.write(cid, hoid2, 0, bl.length(), bl); // make a gap in allocations
    t.write(cid, hoid, block_size * 2 , bl.length(), bl);
    t.clone(cid, hoid, hoid_cloned);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  ch.reset(nullptr);
  bstore->umount();
  cout << "baseline fsck " << bstore->fsck(false) << std::endl;
  bstore->mount();
  {
    bufferlist bl;
    string key;
    _key_encode_u64(1, &key);
    bluestore_shared_blob_t sb(1);
    int r = bstore->get_shared_blob(key, bl);
    ASSERT_EQ(r, 0);
    decode(sb, bl);
    cout << "original " << sb.ref_map << std::endl;
    // precondition: one shared blob with two separate physical extents
    ASSERT_EQ(sb.ref_map.ref_map.size(), 2u);
    auto it = sb.ref_map.ref_map.begin();
    it++;
    sb.ref_map.get(it->first, block_size);   // corrupt: extra ref on 2nd pextent
    cout << "injected " << sb.ref_map << std::endl;
    bl.clear();
    encode(sb, bl);
    bstore->inject_broken_shared_blob_key(key, bl);
  }
  bstore->umount();
  ASSERT_GT(bstore->fsck(false), 0);
  ASSERT_EQ(bstore->repair(false), 0);     // repair claims success
  bstore->mount();
  {
    bufferlist bl;
    string key;
    _key_encode_u64(1, &key);
    bluestore_shared_blob_t sb(1);
    ASSERT_EQ(bstore->get_shared_blob(key, bl), 0);
    decode(sb, bl);
    cout << "after repair " << sb.ref_map << std::endl;
    // expected: both pextents present with refs == 2 (head + clone)
    EXPECT_EQ(sb.ref_map.ref_map.size(), 2u);
  }
  bstore->umount();
  // BUG: prints "shared blob references aren't matching" -> non-zero
  EXPECT_EQ(bstore->fsck(false), 0);
  bstore->mount();
}
