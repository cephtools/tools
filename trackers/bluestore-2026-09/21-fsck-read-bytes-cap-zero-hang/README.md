# bluestore_fsck_read_bytes_cap=0 makes deep fsck/repair loop forever

| | |
|---|---|
| Component | bluestore (fsck), configuration |
| Kind | hang (100% CPU) |
| Severity | minor |
| Config | `bluestore_fsck_read_bytes_cap=0` (level advanced, default 64M, runtime, no `min`) with a deep fsck: `ceph-bluestore-tool fsck/repair --deep`, or an OSD with `bluestore_fsck_on_mount=true` and `bluestore_fsck_on_mount_deep=true` (both dev, default false) |
| Affected | main, since ced308000ae (v14.1.0). Reproduced on origin/main 8e6a13e7a9a |

## Summary
In the deep branch of `_fsck_check_objects()` (BlueStore.cc:11038-11057):
```
uint64_t max_read_block = cct->_conf->bluestore_fsck_read_bytes_cap;
uint64_t offset = 0;
do {
  uint64_t l = std::min(uint64_t(o->onode.size - offset), max_read_block);
  ...
  offset += l;
} while (offset < o->onode.size);
```
With the cap at 0, `l` is 0, `offset` never advances, and the loop never ends for any
object with size > 0 (the OSD superblock written by mkfs is enough). Ceph often uses 0
to mean "unlimited", so this value is a plausible thing to set.

## Reproduction
`repro.sh`: mkfs a 4G OSD; run `fsck --deep 1` with the default cap (control) and with
`--bluestore_fsck_read_bytes_cap=0` under `timeout 120`.

## Observed (origin/main 8e6a13e7a9a)
```
== control: fsck --deep 1 with default cap
fsck success
rc=0
== fsck --deep 1 with bluestore_fsck_read_bytes_cap=0 (timeout 120s)
rc=124 after 120s
```
A 5 s run at `debug_bluestore=20` logs 5,267,035 lines of zero-length reads.

## Suggested fix
Add `min: 4_K` to the option and guard in code as well
(`max_read_block = std::max<uint64_t>(cap, min_alloc_size)`, or treat 0 as "no cap"),
since the yaml `min` does not protect callers that set the value through the API.
