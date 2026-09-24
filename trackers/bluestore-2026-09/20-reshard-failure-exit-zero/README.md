# ceph-bluestore-tool reshard exits 0 when resharding fails

| | |
|---|---|
| Component | ceph-bluestore-tool |
| Kind | tool reports success on failure (automation may proceed with a half-resharded / locked DB) |
| Severity | minor |
| Affected | ceph main @ 98fb1cf8c58 |
| Status | CONFIRMED on c28 2026-09-24 |

## Summary
`bluestore_tool.cc:1397-1403` prints `error resharding: ...` but does not
`exit(EXIT_FAILURE)`. This covers bad specs (-EINVAL) and mid-way failures that
leave the "resharding in progress" marker (OSD refuses to open).

## Reproduction
`repro.sh`: `ceph-bluestore-tool --path <osd> --sharding "m(x) p(3)" reshard; echo $?`

## Observed (c28)
```
error resharding: (22) Invalid argument
rc=0
```

## Suggested fix
Return a non-zero exit code on any reshard error.
