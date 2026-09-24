# bluestore_fsck_read_bytes_cap=0 makes deep fsck/repair loop forever

| | |
|---|---|
| Component | bluestore (fsck), configuration |
| Kind | hang (100% CPU); OSD with deep fsck on mount never boots |
| Severity | minor |
| Affected | ceph main @ 98fb1cf8c58; since ced308000ae |
| Status | CONFIRMED on c28 2026-09-24 |

## Summary
Option has no `min` (global.yaml.in ~5640). In `_fsck_check_objects` deep branch
(BlueStore.cc:11038-11055) `l = min(size - offset, max_read_block)` is 0 when the
cap is 0; `_do_read` returns 0 bytes, `offset += 0`, `while (offset < size)` never ends.

## Reproduction
`repro.sh`: mkfs a 4G OSD; `fsck --deep 1` (control) and
`fsck --deep 1 --bluestore_fsck_read_bytes_cap=0` under `timeout 120`.

## Observed (c28)
```
== control: fsck --deep 1 with default cap -> fsck success, rc=0
== cap=0 -> rc=124 after 120s; 5s at debug_bluestore=20 logs 5896170 lines ('_do_read 0x0~0')
```

## Suggested fix
Add `min: 4_K` (or treat 0 as "no cap").
