// A client op vector [omap_set(b), omap_rm_range(a,c)] reaches the store as
// one Transaction: omap_setkeys + omap_rmkeyrange (PGTransaction keeps order).
TEST_P(StoreTest, OmapRmKeyRangeSeesSameTxnKeys) {
  coll_t cid(spg_t(pg_t(0, 777), shard_id_t::NO_SHARD));
  ghobject_t hoid(hobject_t("omap_rmrange_same_txn", "", CEPH_NOSNAP, 0, 777, ""));
  auto ch = store->create_new_collection(cid);
  int r;
  {
    ObjectStore::Transaction t;
    t.create_collection(cid, 0);
    t.touch(cid, hoid);
    map<string, bufferlist> m;
    m["a"].append("committed");
    m["d"].append("outside");
    t.omap_setkeys(cid, hoid, m);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  {
    ObjectStore::Transaction t;
    map<string, bufferlist> m;
    m["b"].append("same-txn");
    t.omap_setkeys(cid, hoid, m);
    t.omap_rmkeyrange(cid, hoid, "a", "c");   // must remove a and b
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  {
    bufferlist h;
    map<string, bufferlist> out;
    r = store->omap_get(ch, hoid, &h, &out);
    ASSERT_EQ(r, 0);
    EXPECT_EQ(0u, out.count("a"));
    EXPECT_EQ(0u, out.count("b")) << "key set earlier in the same txn survived rmkeyrange";
    EXPECT_EQ(1u, out.count("d"));
    EXPECT_EQ(1u, out.size());
  }
  {
    ObjectStore::Transaction t;
    t.remove(cid, hoid);
    t.remove_collection(cid);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
}

// setkeys + omap_clear in one txn: BlueStore clears the FLAG_OMAP but leaves
// the keys/header in the DB (same nid); the next omap write resurrects them.
TEST_P(StoreTest, OmapClearSeesSameTxnKeys) {
  coll_t cid(spg_t(pg_t(0, 778), shard_id_t::NO_SHARD));
  ghobject_t hoid(hobject_t("omap_clear_same_txn", "", CEPH_NOSNAP, 0, 778, ""));
  auto ch = store->create_new_collection(cid);
  int r;
  {
    ObjectStore::Transaction t;
    t.create_collection(cid, 0);
    t.touch(cid, hoid);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  {
    ObjectStore::Transaction t;
    map<string, bufferlist> m;
    m["stale"].append("should-be-cleared");
    bufferlist hdr;
    hdr.append("stale-header");
    t.omap_setheader(cid, hoid, hdr);
    t.omap_setkeys(cid, hoid, m);
    t.omap_clear(cid, hoid);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  {
    bufferlist h;
    map<string, bufferlist> out;
    r = store->omap_get(ch, hoid, &h, &out);
    ASSERT_EQ(r, 0);
    EXPECT_EQ(0u, out.size());
    EXPECT_EQ(0u, h.length());
  }
  {
    ObjectStore::Transaction t;
    map<string, bufferlist> m;
    m["fresh"].append("v");
    t.omap_setkeys(cid, hoid, m);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  {
    bufferlist h;
    map<string, bufferlist> out;
    r = store->omap_get(ch, hoid, &h, &out);
    ASSERT_EQ(r, 0);
    EXPECT_EQ(0u, out.count("stale")) << "cleared omap key resurrected";
    EXPECT_EQ(0u, h.length()) << "cleared omap header resurrected";
    EXPECT_EQ(1u, out.size());
  }
  {
    ObjectStore::Transaction t;
    t.remove(cid, hoid);
    t.remove_collection(cid);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
}

// clone after setkeys in the same txn: BlueStore's _clone copies omap by
// iterating the committed DB, so keys set on the source earlier in the same
// txn are not copied, and keys set on the destination earlier in the same
// txn are not cleared.
TEST_P(StoreTest, OmapCloneSeesSameTxnKeys) {
  coll_t cid(spg_t(pg_t(0, 779), shard_id_t::NO_SHARD));
  ghobject_t src(hobject_t("omap_clone_src", "", CEPH_NOSNAP, 0x1234, 779, ""));
  ghobject_t dst(hobject_t("omap_clone_src", "", 5, 0x1234, 779, ""));
  auto ch = store->create_new_collection(cid);
  int r;
  {
    ObjectStore::Transaction t;
    t.create_collection(cid, 0);
    t.touch(cid, src);
    t.touch(cid, dst);
    map<string, bufferlist> m;
    m["old"].append("x");
    t.omap_setkeys(cid, src, m);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  {
    ObjectStore::Transaction t;
    map<string, bufferlist> ms, md;
    ms["new"].append("y");
    md["junk"].append("z");
    t.omap_setkeys(cid, src, ms);
    t.omap_setkeys(cid, dst, md);
    t.clone(cid, src, dst);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  {
    bufferlist h;
    map<string, bufferlist> out;
    r = store->omap_get(ch, dst, &h, &out);
    ASSERT_EQ(r, 0);
    EXPECT_EQ(1u, out.count("old"));
    EXPECT_EQ(1u, out.count("new")) << "source key set in same txn not cloned";
    EXPECT_EQ(0u, out.count("junk")) << "dest key set in same txn not cleared by clone";
    EXPECT_EQ(2u, out.size());
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

// setkeys + remove in one txn leaks the omap keys (fsck: stray per-pg omap).
TEST_P(StoreTest, OmapRemoveSeesSameTxnKeys) {
  if (string(GetParam()) != "bluestore")
    return;
  coll_t cid(spg_t(pg_t(0, 780), shard_id_t::NO_SHARD));
  ghobject_t hoid(hobject_t("omap_remove_same_txn", "", CEPH_NOSNAP, 0, 780, ""));
  auto ch = store->create_new_collection(cid);
  int r;
  {
    ObjectStore::Transaction t;
    t.create_collection(cid, 0);
    t.touch(cid, hoid);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  {
    ObjectStore::Transaction t;
    map<string, bufferlist> m;
    m["k"].append("v");
    t.omap_setkeys(cid, hoid, m);
    t.remove(cid, hoid);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
  ch.reset();
  EXPECT_EQ(store->umount(), 0);
  EXPECT_EQ(store->fsck(false), 0) << "stray omap left behind by remove";
  EXPECT_EQ(store->mount(), 0);
  ch = store->open_collection(cid);
  {
    ObjectStore::Transaction t;
    t.remove_collection(cid);
    r = queue_transaction(store, ch, std::move(t));
    ASSERT_EQ(r, 0);
  }
}
