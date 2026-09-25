# More per-op costs in the OSD: allocations, peer lookups, copies

| | |
|---|---|
| Area | primary and replica write path, read path |
| Change | small each |
| Expected gain | these sit in the profile's allocation and copy bucket: `new`/`delete` ~2.9%, `memmove` 2.3%, bufferlist append/copy ~3.4% of OSD CPU on writes; most items are well under 1 µs per op (F6 can be several µs on large maps) (estimates) |
| Risk | low to medium |
| Status | code analysis (verified in the source); only the data digest (F5) is being measured |

Found by a second hunt of the generic path, re-ranked against the perf
profile. All line numbers are v21.3.0 `src/`.

| # | Finding | Evidence | Change |
|---|---|---|---|
| F7 | about 12 small heap objects per primary write only to track completion: 3 `std::function` lists, `RepGather`, `C_OSD_RepopCommit`, `InProgressOp` plus its map node, a 3-node `waiting_for_commit` set, `C_OSD_OnOpCommit` + `BlessedContext`, the `tls` vector | `PrimaryLogPG.cc:4473-4498, 11715, 11752`; `ReplicatedBackend.cc:626-673` | direct calls instead of the lambda lists on the normal path; a bitmask for `waiting_for_commit`; allocate `InProgressOp` with the `RepGather` |
| F8 | per read and write: the object lock manager inserts a map node (and copies the object name), and `put_locks` always adds a list entry, so every op also runs the scrub check and an empty requeue; `MOSDOpReply` copies the request's ops, including a reference to the 4 KiB write data (an allocation and a reference count, no data bytes), only to clear it | `osd_internal_types.h:208-324`; `PrimaryLogPG.cc:1743-1770`; `messages/MOSDOpReply.h:147-164` | an inline slot for the first lock; add to the requeue list only when something waits; build the reply's ops without the data |
| F4 | each cluster send (4 per client write) takes the OSD-wide `pre_publish_lock` twice and allocates a map node (`get_nextmap_reserved` / `release_map`), takes the messenger-wide lock in `connect_to`, and copies the address vector (`_filter_addrs`) | `OSD.cc:582-609, 1116-1140`; `msg/async/AsyncMessenger.cc:905-981` | cache the connection per interval; `release_map` by const reference; no address copy |
| F3 | `write_if_dirty` deep-copies `pg_info_t` on every write, on all 3 OSDs, even when the fast-info path has just made the two equal | `PeeringState.cc:567`; `osd_types.cc:7610-7620` | skip the copy when the fast path was taken (needs `prepare_write` to say so) |
| F2 | on a replicated pool the primary adds each log entry to `projected_log` and trims it at once; each trim builds a dup entry, so every PG keeps a second list of up to 3000 dups that the real log already has, and `check_in_progress_op` probes both dup indexes per write | `PrimaryLogPG.h:535-537`; `PGLog.cc:56-152`; `PG.cc:782-795` | trim `projected_log` without making dups |
| F5 | `osd_skip_data_digest` defaults to false, so every whole-object write and read computes crc32c over the data on top of BlueStore's own checksum | `common/options` default `false` | config: `osd_skip_data_digest = true` (being measured) |
| F6 | `OSDMap::get_features` is recomputed for every write to encode `object_info_t`: crush tunable checks and loops over all pools and rules (and primary affinity when set); cheap on a small test map, several µs on large maps (estimate) | `PrimaryLogPG.cc:9258-9259`; `OSDMap.cc:1761-1852` | cache the feature word per map epoch |
| F1 | a replica copies the whole local missing set for every replicated write (the same bug as the EC one in record 13) | `ReplicatedBackend.cc:1335` | `const auto &` — free on a clean cluster, O(missing) during recovery |

## How to observe

The allocation bucket needs call graphs: build with frame pointers
(`-fno-omit-frame-pointer`), because DWARF unwinding failed through Ceph's
C++ frames in this lab. Then `perf report` callers of `operator new` under
`PrimaryLogPG::execute_ctx`, `ReplicatedBackend::submit_transaction` and
`MOSDOpReply::MOSDOpReply`.

## Workload

`rados bench -b 4096 -t 64 write` and `rand` on ramdisk OSDs; for F1, the same
while an OSD recovers (`ceph osd out` / `in`).
