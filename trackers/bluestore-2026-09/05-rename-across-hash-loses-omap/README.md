# _rename (collection_move_rename) to an oid with a different hash orphans per-pg omap

| | |
|---|---|
| Component | bluestore |
| Kind | data loss (omap), fsck stray omap |
| Severity | minor/major (OSD renames temp objects that share the target hash; ObjectStore API allows any) |
| Affected | ceph main @ 98fb1cf8c58 (since per-pg omap, OMAP_PER_PG) |
| Status | CONFIRMED on c28 2026-09-24 (memstore passes) |

## Summary
Per-pg omap keys embed the object's hash:
`Onode::calc_omap_key/header` (BlueStore.cc:4863-4893) encode
`pool | oid.hobj.get_bitwise_key_u32() | nid`. `_rename` (BlueStore.cc:19034)
keeps the onode nid and rewrites extent shards but never rewrites omap keys, so
after renaming to an oid with a different hash the omap is looked up under a new
prefix: omap and header are gone, old keys become stray (fsck error after remove).

## Reproduction
`test.cc` -> `StoreTest.RenameAcrossHashKeepsOmap`: src hash 0x11111111 with omap+header,
`collection_move_rename` to dst hash 0x22222222, read omap, remove, fsck.

## Observed (c28)
```
out.count("k1") Which is: 0   "omap lost by rename across hash"
bl_eq(hdr, h) false           "omap header lost by rename across hash"
fsck after remove != 0        (stray per-pg omap)
memstore: [ OK ]
```

## Expected
omap and header follow the object (as in MemStore); no stray keys.

## Suggested fix
In `_rename`, when old and new omap prefixes differ (per-pg, different hash),
rewrite the omap keys (like `_clone` does with `rewrite_omap_key`) or reject it.
