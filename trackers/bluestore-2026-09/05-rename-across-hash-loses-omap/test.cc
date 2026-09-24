// ===== candidate: rename-perpg-omap-hash
// Candidate: _rename keeps the onode nid but per-pg omap keys embed the
// object's hash (Onode::calc_omap_key uses o->oid.hobj.get_bitwise_key_u32()).
// Renaming to an oid with a different hash orphans the omap.
// Paste inside #ifdef WITH_BLUESTORE near the end of store_test.cc.
TEST_P(StoreTest, RenameAcrossHashKeepsOmap) {
  coll_t cid(spg_t(pg_t(0, 781), shard_id_t::NO_SHARD));
  ghobject_t src(hobject_t("rename_src", "", CEPH_NOSNAP, 0x11111111, 781, ""));
  ghobject_t dst(hobject_t("rename_dst", "", CEPH_NOSNAP, 0x22222222, 781, ""));
  auto ch = store->create_new_collection(cid);
  int r;
  bufferlist hdr;
  hdr.append("hdr");
  {
    ObjectStore::Transaction t;
    t.create_collection(cid, 0);   // bits 0: both hashes belong here
    t.touch(cid, src);
    map<string, bufferlist> m;
    m["k1"].append("v1");
    t.omap_setkeys(cid, src, m);
    t.omap_setheader(cid, src, hdr);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  {
    ObjectStore::Transaction t;
    t.collection_move_rename(cid, src, cid, dst);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  ASSERT_FALSE(store->exists(ch, src));
  ASSERT_TRUE(store->exists(ch, dst));
  {
    bufferlist h;
    map<string, bufferlist> out;
    r = store->omap_get(ch, dst, &h, &out);
    ASSERT_EQ(r, 0);
    EXPECT_EQ(1u, out.count("k1")) << "omap lost by rename across hash";
    EXPECT_TRUE(bl_eq(hdr, h)) << "omap header lost by rename across hash";
  }
  {
    ObjectStore::Transaction t;
    t.remove(cid, dst);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  if (string(GetParam()) == "bluestore") {
    // removing dst clears the *new-hash* range only; old keys become stray
    ch.reset();
    EXPECT_EQ(store->umount(), 0);
    EXPECT_EQ(store->fsck(false), 0) << "stray per-pg omap after rename+remove";
    EXPECT_EQ(store->mount(), 0);
    ch = store->open_collection(cid);
  }
  {
    ObjectStore::Transaction t;
    t.remove_collection(cid);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
}
