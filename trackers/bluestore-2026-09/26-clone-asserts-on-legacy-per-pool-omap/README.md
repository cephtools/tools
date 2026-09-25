# BlueStore: snapshot copy-on-write of an Octopus-era (per-pool omap) object aborts the OSD in _clone

| | |
|---|---|
| Component | bluestore |
| Kind | OSD crash (ceph_assert) on a normal client write; the PG crash-loops because every replica and every client retry hits it |
| Severity | major for affected clusters |
| Config | default; OSD created on Octopus (per-pool omap, `per_pool_omap=1`) and never converted to per-pg omap. Conversion only happens with `ceph-bluestore-tool quick-fix`/repair or `bluestore_fsck_quick_fix_on_mount=true` (dev, default false; off by default since 16.2.7) |
| Real-world | **Confirmed on a live OSD**: a self-managed snapshot followed by a 4K librados write to an omap object with Octopus-era flags aborts the OSD |
| Affected | main (and every release since per-pg omap, Pacific). Reproduced on origin/main 8e6a13e7a9a |

## Summary
`BlueStore::_clone()` (BlueStore.cc:18904-18920) gives the clone target the omap flags
of the *current store-wide mode*, then asserts that they match the source's flags:
```
if (oldo->onode.has_omap()) {
  if (newo->oid.is_pgmeta()) newo->onode.set_omap_flags_pgmeta();
  else newo->onode.set_omap_flags(per_pool_omap == OMAP_BULK);  // OMAP|PERPOOL|PERPG
  // check if prefix for omap key is exactly the same size for both objects
  ceph_assert(oldo->onode.flags == newo->onode.flags);
```
Objects written by Octopus carry `FLAG_OMAP | FLAG_PERPOOL_OMAP` (0x5, per-pool keys);
per-pg omap (`FLAG_PERPG_OMAP`, 0x8) came with Pacific. On an OSD that was never
converted (fsck only reports "has omap that is not per-pg"), such objects stay 0x5, while
`set_omap_flags(false)` always yields 0xd. The first copy-on-write clone of any such
object — a write after a pool snapshot or a self-managed (RBD/CephFS) snapshot, or a
rollback — hits the assert. The assert was added by 0be2c26a25b (2021) to avoid key
corruption in `rewrite_omap_key()`; the missing piece is copying (or converting) the
source's omap format instead of asserting.

## Reproduction
`live-osd-repro.sh`: vstart 1 OSD; create an object with 8 omap keys; stop the OSD and
give the store the Octopus on-disk shape with `ceph-kvstore-tool` (object flags 0xd -> 0x5,
`S/per_pool_omap=1`, keys moved from prefix `p` to `m`); fsck; start the OSD; create a
self-managed snapshot and write 4K to the object.

Note: in the runs below the conversion's key move stopped at the first key because
`ceph-kvstore-tool set` aborted on it (a tool problem, not investigated). The flag
change to the Octopus value 0x5 was applied, and the assert depends only on the flags.

## Observed (origin/main 8e6a13e7a9a, live OSD; same result in 3 runs)
```
nid 1156 flags before 0xd
flags after  0x5
-- fsck of the converted (Octopus-like) store
fsck error: #1:cfbcdcae:::omapobj:head# has omap that is not per-pg or pgmeta
-- omap still readable:
k00 k01 k02 k03 k04 k05 k06 k07
-- self-managed snapshot + 4K write -> make_writeable clones omapobj
write failed: [errno 110] RADOS timed out (Ioctx.write(p): failed to write omapobj)
BUG: OSD crashed cloning a legacy omap object:
src/os/bluestore/BlueStore.cc: 18919: FAILED ceph_assert(oldo->onode.flags == newo->onode.flags)
```

## Expected
The clone gets the same omap format as its source (or the source is converted in the
same transaction); the write succeeds.

## Suggested fix
In `_clone()`, copy the source's omap flags to the target
(`newo->onode.flags = (newo->onode.flags & ~omap_flags) | (oldo->onode.flags & omap_flags)`)
so `rewrite_omap_key()` sees identical prefix layouts, or convert the source to per-pg
first.
