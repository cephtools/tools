# bluestore_min_alloc_size is typed uint (SI decimal) while _hdd/_ssd are size: "64K" means 64000

| | |
|---|---|
| Component | bluestore, configuration (options yaml) |
| Kind | configuration / mkfs failure |
| Severity | minor |
| Affected | ceph main (verified at 8e6a13e7a9a, 2026-09-24; also 98fb1cf8c58) |
| Related | tracker 72263 (feature request about int/uint multipliers) is not this bug |
| Status | CONFIRMED on clean ceph origin/main 8e6a13e7a9a (2026-09-24, only the test patch applied; see common/verify-origin-main-8e6a13e7a9a.txt); first found on 98fb1cf8c58 |

## Summary
`global.yaml.in`: `bluestore_min_alloc_size` is `type: uint`, its siblings
`bluestore_min_alloc_size_hdd/_ssd` are `type: size`. `uint` values are parsed with
`strict_si_cast` (decimal), so `64K` = 64000, and mkfs fails. The same string works
for the `_hdd`/`_ssd` variants. `bluestore_debug_enforce_min_alloc_size` is also
`uint` and is used without a power-of-2 check in `_open_super_meta`.

## Reproduction
`repro.sh`: `ceph-conf --show-config-value` for both options; mkfs with
`--bluestore-min-alloc-size-hdd=64K` (ok) and `--bluestore-min-alloc-size=64K`.

## Observed (c28)
```
bluestore_min_alloc_size=64K     -> 64000
bluestore_min_alloc_size_hdd=64K -> 65536
mkfs min_alloc_size 0xfa00 is not power of 2 aligned!
```

## Suggested fix
Change `bluestore_min_alloc_size` (and `bluestore_debug_enforce_min_alloc_size`) to `type: size`.
