# ceph-bluestore-tool reshard exits 0 when resharding fails

| | |
|---|---|
| Component | ceph-bluestore-tool |
| Kind | wrong exit status; scripts cannot detect the failure |
| Severity | minor |
| Config | any |
| Affected | main. Reproduced on origin/main 8e6a13e7a9a |

## Summary
The `reshard` action (bluestore_tool.cc:1397-1403) prints `error resharding: ...` but
does not `exit(EXIT_FAILURE)`, so the tool exits 0. This covers:
- a bad sharding spec: `-EINVAL` from `prepare_for_reshard()`, returned before the
  resharding lock is taken, so the DB is unchanged (the repro case);
- errors after the lock is taken (`reshard_cleanup()` failure, `-EIO` writing the sharding
  definition, RocksDBStore.cc:3775-3923), which may leave the
  `reshardingXcommencingXlocked` marker; the OSD then refuses to open while the tool
  still reported success.

## Reproduction
`repro.sh`: `ceph-bluestore-tool --path <osd> --sharding "m(x) p(3)" reshard; echo $?`

## Observed (origin/main 8e6a13e7a9a)
```
== current sharding
m(3) p(3,0-12) O(3,0-13)=block_cache={type=binned_lru} L=min_write_buffer_number_to_merge=32 P=min_write_buffer_number_to_merge=32
== reshard with an invalid spec (parse error -> -EINVAL)
error resharding: (22) Invalid argument
rc=0
```

## Suggested fix
Exit with a non-zero status on any reshard error.
