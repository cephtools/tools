# bluestore_max_blob_size{,_hdd,_ssd}=0 ("no limit") crashes write_v2 with SIGFPE

| | |
|---|---|
| Component | bluestore, configuration |
| Kind | crash (every uncompressed write) |
| Severity | minor/major (write_v2 non-default; options are runtime) |
| Affected | ceph main (verified at 8e6a13e7a9a, 2026-09-24; also 98fb1cf8c58) |
| Status | CONFIRMED on clean ceph origin/main 8e6a13e7a9a (2026-09-24, only the test patch applied; see common/verify-origin-main-8e6a13e7a9a.txt); first found on 98fb1cf8c58 |

## Summary
The options are type `size`, `runtime`, no `min` (global.yaml.in:5045-5074); the
doc says 0 = "no limit". `_set_blob_size()` copies 0 into `max_blob_size`;
`_choose_write_options()` sets `wctx->target_blob_size = max_bsize = 0`. v1 hides it
with `max(target_blob_size, min_alloc_size)`, but `Writer::_split_data()`
(Writer.cc:1346,1350) divides by it -> SIGFPE.

## Reproduction
`test.cc` -> `StoreTestSpecificAUSize.ZeroMaxBlobSizeWriteV2` (write_v2=true, all three options 0, write 64K).
Cluster: `ceph config set osd bluestore_max_blob_size_ssd 0; ... _hdd 0` with write_v2 enabled.

## Observed (c28)
```
*** Caught signal (Floating point exception) **
 2: (BlueStore::Writer::_split_data(unsigned int, ceph::buffer::list&, ...)+0x63)
 3: (BlueStore::Writer::do_write(unsigned int, ceph::buffer::list&)+0x93)
 4: (BlueStore::_do_write_v2(...)
```

## Suggested fix
Treat 0 as "unlimited" consistently (e.g. clamp to a max blob size) or add `min`
validation; also guard `_split_data` / `can_reuse_blob` against 0.
