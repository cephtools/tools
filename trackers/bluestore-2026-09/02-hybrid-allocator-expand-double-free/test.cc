// Online expand (BlueStore::expand_devices) calls alloc->expand(new) and then
// alloc->init_add_free(old, new - old).  Once the hybrid allocator has spilled
// over into its bitmap fallback, expand() also marks [old, new) free in the
// bitmap, so the new range ends up free in BOTH the tree and the bitmap and
// can be handed out twice.
TEST(HybridAllocator, expand_after_spillover)
{
  uint64_t block_size = 0x1000;
  uint64_t capacity = 0x100 * _1m; // 256MB
  TestHybridAllocator ha(g_ceph_context, capacity, block_size,
    4 * sizeof(range_seg_t), "test_hybrid_allocator");

  // fragmented free space to force spillover into the bitmap
  for (uint64_t o = 0; o < 16 * _1m; o += 2 * 0x1000) {
    ha.init_add_free(o, 0x1000);
  }
  ASSERT_TRUE(ha.has_bmap());
  uint64_t free_before = ha.get_free();

  // same sequence as BlueStore::expand_devices() online path
  ha.expand(2 * capacity);
  ha.init_add_free(capacity, capacity);

  // free space must grow by exactly the added range
  EXPECT_EQ(free_before + capacity, ha.get_free());

  // no byte may be reported free twice
  std::map<uint64_t, uint64_t> seen;
  uint64_t overlap = 0;
  ha.foreach([&](uint64_t o, uint64_t l) {
    for (uint64_t p = o; p < o + l; p += block_size) {
      if (seen[p]++) overlap += block_size;
    }
  });
  EXPECT_EQ(0u, overlap) << "bytes free in both tree and bitmap";

  // allocate everything: no extent may be handed out twice
  PExtentVector all;
  int64_t got;
  while ((got = ha.allocate(capacity, block_size, capacity, 0, &all)) > 0) {
  }
  std::map<uint64_t, uint64_t> owned;
  uint64_t dup = 0;
  for (auto& e : all) {
    for (uint64_t p = e.offset; p < e.offset + e.length; p += block_size) {
      if (owned[p]++) dup += block_size;
    }
  }
  EXPECT_EQ(0u, dup) << "bytes allocated twice";
}
