# bluestore_max_alloc_size (and other documented BlueStore options, incl. bluestore_qfsck_on_mount=true) are silently ignored

| | |
|---|---|
| Component | bluestore, configuration |
| Kind | configuration ignored |
| Severity | minor |
| Affected | ceph main (verified at 8e6a13e7a9a, 2026-09-24; also 98fb1cf8c58) |
| Status | CONFIRMED on clean ceph origin/main 8e6a13e7a9a (2026-09-24, only the test patch applied; see common/verify-origin-main-8e6a13e7a9a.txt); first found on 98fb1cf8c58 |

## Summary
- `bluestore_max_alloc_size` ("Maximum size of a single allocation"): `_set_alloc_sizes()`
  (BlueStore.cc:7231) copies it into `max_alloc_size`, which is only logged; no
  `allocate()` call uses it since e200f358499 (2017). It is also listed in
  `get_tracked_keys()` and handled at runtime although the yaml flags it `create`.
- `bluestore_qfsck_on_mount` (default **true**, "Run quick-fsck at mount ...") was added
  in 9b2a64a5f6e but never wired up: no code reads it.
- Also unused: `bluestore_bluefs_max_free`, `bluestore_cleaner_sleep_interval`,
  `bluestore_cache_trim_max_skip_pinned`, `bluestore_bitmapallocator_blocks_per_zone`,
  `bluestore_bitmapallocator_span_size`, `bluestore_debug_prefragment_max`,
  `bluestore_debug_freelist`, `bdev_nvme_unbind_from_kernel`.

## Reproduction
- `test.cc` -> `StoreTestSpecificAUSize.MaxAllocSizeIgnored` (needs `#include <regex>`):
  `bluestore_max_alloc_size=64K`, `bluestore_max_blob_size=1M`, write 1 MiB, inspect pextents.
- `check-unused-options.sh`: static check (`SRC=<ceph checkout>`) listing options with no consumer.

## Observed (c28)
```
bluestore_max_alloc_size=64K ignored: physical extent of 0x100000
pextents 1 largest 0x100000
```

## Suggested fix
Either honor `bluestore_max_alloc_size` in the allocate paths (v1 `_do_alloc_write`,
v2 `Writer::_defer_or_allocate`) or remove/deprecate it; implement or remove
`bluestore_qfsck_on_mount`; drop the other dead options.
