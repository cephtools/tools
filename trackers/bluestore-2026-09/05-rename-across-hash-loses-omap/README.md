# BlueStore: collection_move_rename to an oid with a different hash orphans its per-pg omap

| | |
|---|---|
| Component | bluestore |
| Kind | omap loss via the ObjectStore API; fsck reports stray omap |
| Severity | minor |
| Config | default (per-pg omap, `p` prefix; per-pool, bulk and pgmeta omap are not affected) |
| Affected | main since per-pg omap (Pacific). Reproduced on origin/main 8e6a13e7a9a; MemStore passes |

## Summary
Per-pg omap keys embed the object's hash: `Onode::calc_omap_header()` /
`calc_omap_key()` (BlueStore.cc:4862-4892) encode
`pool | oid.hobj.get_bitwise_key_u32() | nid`. `_rename()` (BlueStore.cc:19034)
keeps the onode nid and rewrites the extent-map shards, but never rewrites the omap
keys. After renaming to an oid with a different hash, the omap is looked up under a
new prefix: omap and header disappear, and the old keys become stray (fsck error).

The OSD itself does not rename across hash: temp and recovery objects keep the target
hash (`make_temp_hobject`, hobject.h:308). The ObjectStore contract allows it,
however, and MemStore handles it correctly.

## Reproduction
gtest `StoreTest.RenameAcrossHashKeepsOmap` (`test.cc`): source hash 0x11111111 with
omap and header, `collection_move_rename` to destination hash 0x22222222 in the same
collection, read omap, remove, fsck.

## Observed (origin/main 8e6a13e7a9a; memstore `[ OK ]`)
```
store_test.cc:12966: Failure
  out.count("k1")
    Which is: 0
omap lost by rename across hash
store_test.cc:12967: Failure
Value of: bl_eq(hdr, h)
  Actual: false
omap header lost by rename across hash
fsck error: found stray (per-pg) omap data on omap_head  key 0x000000000000030D8888888800000000000000012D1 0 0
  store->fsck(false)
    Which is: 1
```

## Expected
Omap and header follow the object (as in MemStore); no stray keys.

## Suggested fix
In `_rename()`, when the old and new omap prefixes differ (per-pg, different hash),
rewrite the omap keys (as `_clone()` does with `rewrite_omap_key()`), or reject the
operation explicitly.
