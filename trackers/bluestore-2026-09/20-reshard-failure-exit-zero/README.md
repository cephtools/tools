# ceph-bluestore-tool reshard exits 0 when resharding fails

| | |
|---|---|
| Component | ceph-bluestore-tool |
| Kind | tool reports success on failure (automation may proceed with a half-resharded / locked DB) |
| Severity | minor |
| Affected | ceph main (verified at 8e6a13e7a9a, 2026-09-24; also 98fb1cf8c58) |
| Status | CONFIRMED on clean ceph origin/main 8e6a13e7a9a (2026-09-24, only the test patch applied; see common/verify-origin-main-8e6a13e7a9a.txt); first found on 98fb1cf8c58 |

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
