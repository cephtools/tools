# A replica's reply is handled as a full op on the primary

| | |
|---|---|
| Area | messenger → op queue → `ReplicatedBackend::do_repop_reply` |
| Change | small (untracked replies); medium (reply inbox) |
| Expected gain | CPU per write; estimates 1–3 µs per reply (a), 10–25 µs per write (b) |
| Risk | low (a); medium (b) |
| Status | code analysis, not measured |

## Summary

For each `MOSDRepOpReply` the primary builds a tracked `OpRequest`, queues a
`PGOpItem`, takes the shard lock and the PG lock, and runs the full
`do_request` checks. The real work is small: erase one entry from
`waiting_for_commit` and maybe complete the repop.

## Theory

Per reply:

- a tracked `OpRequest`: `events.reserve(20)`, `register_inflight_op`, about 8
  `mark_event` calls (each a mutex and a string), an op-history insert when it
  is freed;
- two no-op tracing spans, a `PGOpItem`, the shard lock, the PG lock,
  `maybe_share_map`, `can_discard_replica_op`.

Replies are queued as `immediate`, not scheduled by mClock
(`PGOpItem::get_scheduler_class`, `osd/scheduler/OpSchedulerItem.h:240`). The
parent client op already records `sub_op_commit_rec`, so tracking the reply
itself adds nothing to the op history.

## Proposed change

- (a) Create the `OpRequest` of `MSG_OSD_REPOPREPLY` and
  `MSG_OSD_EC_WRITE_REPLY` untracked. `mark_event` then returns at once, and
  there is no registration or history insert.
- (b) A per-PG reply inbox: the messenger thread pushes the reply and queues
  an item only if the inbox was empty; the worker drains all replies under one
  PG lock. With size 3 the two replies often arrive back to back, so 2 queue
  and lock rounds become 1. The `can_discard_replica_op` checks must run at
  drain time, replies must be applied in arrival order, and `on_change` must
  clear the inbox.

## How to observe

- bpftrace: latency histogram of `ReplicatedBackend::do_repop_reply`; count
  `OpTracker::register_inflight_op` per client write (about 3 today, 1 after
  (a)).
- OSD CPU per IOP.

## Workload

`rados bench -b 4096 -t 64 write` on a size-3 pool (CPU per op); `-t 1` for
latency.
