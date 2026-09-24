# Pool compression_algorithm=none is ignored; data is compressed with the global algorithm

| | |
|---|---|
| Component | bluestore, configuration |
| Kind | configuration ignored (on-disk layout / CPU), regression |
| Severity | minor |
| Affected | ceph main @ 98fb1cf8c58; regression from a6a499ed5fc (2025-01, tracker 69507 "preload compressor plugins") |
| Status | CONFIRMED on c28 2026-09-24 |

## Summary
`BlueStore::set_collection_opts()` (BlueStore.cc:12844-12860) only records the pool
algorithm if `*alg != COMP_ALG_NONE`; for "none" it leaves
`c->compression_algorithm` unset, and `_choose_write_options()` (17949-17952) then
falls back to the global `bluestore_compression_algorithm`. Before a6a499ed5fc
`Compressor::create(cct, "none")` returned nullptr -> no compression. Same fallback
when the pool names an algorithm whose plugin failed to load (alert raised, but the
global algorithm is silently used).

## Reproduction
`test.cc` -> `StoreTestSpecificAUSize.PoolCompressionAlgorithmNoneHonored`
(global mode=force, algorithm=lz4; control pool vs pool with compression_algorithm=none).
Run with `--plugin_dir=<build>/lib` so compressor plugins load.

## Observed (c28)
```
control pool compressed_original=0x40000 none-pool compressed_original=0x40000
b.data_compressed_original ... "pool compression_algorithm=none ignored"
```

## Suggested fix
Store the explicit pool choice even when it is NONE (or an "unavailable" sentinel)
so `_choose_write_options` selects `compressors[NONE] == nullptr`.
