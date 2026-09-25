# bluestore_min_alloc_size is typed uint while _hdd/_ssd are size: "64K" means 64000 and mkfs fails

| | |
|---|---|
| Component | bluestore, configuration (options yaml) |
| Kind | option type mismatch; mkfs fails loudly (no silent misconfiguration) |
| Severity | minor |
| Config | `bluestore_min_alloc_size` given with a unit suffix; workaround: use a plain number (65536) |
| Real-world | **Real tools**: `ceph-conf` and `ceph-osd --mkfs` |
| Affected | main. Reproduced on origin/main 8e6a13e7a9a |
| Related | tracker 72263 (feature request about multipliers for int/uint options) is not this bug |

## Summary
In global.yaml.in `bluestore_min_alloc_size` is `type: uint` (4749-4750), while its
siblings `bluestore_min_alloc_size_hdd` / `_ssd` are `type: size`. `uint` values are
parsed by `strict_si_cast` (decimal), so `64K` = 64000, and mkfs rejects it (-EINVAL,
BlueStore.cc:8851-8858). The same string works for the `_hdd` / `_ssd` variants.

## Reproduction
`repro.sh`: `ceph-conf --show-config-value` for both options; mkfs with
`--bluestore-min-alloc-size-hdd=64K` (control) and `--bluestore-min-alloc-size=64K`.

## Observed (origin/main 8e6a13e7a9a)
```
== config parse
64000          (bluestore_min_alloc_size=64K)
65536          (bluestore_min_alloc_size_hdd=64K)
== mkfs with bluestore_min_alloc_size_hdd=64K (control)
mkfs ok
== mkfs with bluestore_min_alloc_size=64K
mkfs failed
bluestore(/root/bh/mas_generic) mkfs min_alloc_size 0xfa00 is not power of 2 aligned!
```

## Suggested fix
Change `bluestore_min_alloc_size` to `type: size`, like its siblings.
