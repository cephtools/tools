# Thread handoffs and wakeups below the OSD op code

| | |
|---|---|
| Area | BlueStore commit path, AsyncMessenger |
| Change | small to medium |
| Expected gain | profile: futex is 14.8% of OSD CPU on 4k writes (wait 10.4%, wake 4.3%), all system calls 31% |
| Risk | low to high, per item |
| Status | code analysis; the class of cost is profile-backed |

The largest single cost class in the write profile is futex, threads
waiting for and waking each other: 14.8% of OSD CPU (all system calls are
31%, which also counts `io_submit` and `sendmsg`;
`results/profile-2026-09-25/`). Records 01, 05 and 14 cover the op queue and
the messenger ACKs. Below them, a replicated write crosses about 15 threads
on the primary and 10 on each replica:

```
 msgr worker -> tp_osd_tp -> bstore_aio -> bstore_kv_sync -> bstore_kv_final
             -> tp_osd_tp (commit callback) -> msgr worker (eventfd wakeup)
```

| Finding | Evidence | Change | Risk |
|---|---|---|---|
| The commit goes `kv_sync` → `kv_final` → `tp_osd_tp`; the oncommit queueing could run from `kv_sync` right after the synced submit | `BlueStore.cc:15495-15519, 14959-14963` | call `_txc_committed_kv`'s queueing from `kv_sync`; leave the rest on `kv_final` | low–medium |
| At least two RocksDB `Write` calls per kv cycle: one per transaction (`sync=false`) plus the `synct` batch (`sync=true`) | `BlueStore.cc:15399, 15425-15430, 15462-15463` | put `synct`'s content into the last batch, or append all batches into one synced write | medium |
| Every send from `tp_osd_tp` wakes the messenger worker through an eventfd (about 5 per client write) | `ProtocolV2.cc:470-473`; `Event.cc:369-394, 508-521` | send inline when the connection is idle (an older inline mode was removed for races) | high |
| About 12 latency counters and 15 other counters per transaction on shared atomics, and a global mutex in `BlueStoreThrottle::try_start_transaction` only to track a maximum | `BlueStore.cc:19349, 19370-19381`; `perf_counters.cc:296-320` | per-thread counters; relaxed atomics for the maximum | low |

(`bluefs_sync_write` is left out here: it was investigated separately.)

## How to observe

bpftrace counts of `sched:sched_wakeup` by waker/wakee thread name per client
op; `perf record -e syscalls:sys_enter_futex` with user call graphs (frame
pointers needed in this lab).

## Workload

`rados bench -b 4096 -t 1` and `-t 64 write` on ramdisk OSDs.
