# Deep scrub reads a whole chunk in one PG-lock hold

| | |
|---|---|
| Area | scrub (`PgScrubber::build_scrub_map_chunk`) |
| Change | ~3 lines |
| Expected gain | client p99 on the scrubbed PG and its replicas during deep scrub |
| Risk | low |
| Status | code analysis, not measured |

## Summary

Deep scrub is meant to yield (return `-EINPROGRESS` and requeue) between
reads. It only yields when an object is **larger** than one stride
(`osd_deep_scrub_stride`, 4 MiB) or has more omap keys than
`osd_deep_scrub_keys`. For objects of 4 MiB or less (RBD and CephFS defaults)
the loop moves straight on to the next object. So one PG-lock hold reads and
checksums a whole chunk: up to `osd_scrub_chunk_max` = 15 objects, about
60 MiB. Every client op to that PG waits.

## Theory

```
 build_scrub_map_chunk
   while (!pos.done())                                   pg_scrubber.cc:1483
     be_scan_list                                        PGBackend.cc:930
       stat + getattrs
       be_deep_scrub                                     ReplicatedBackend.cc:855
         read up to 4 MiB, hash
           object done -> nullopt, go on                 ReplicatedBackend.cc:843
         omap_iterate (osd_deep_scrub_keys)
           -EINPROGRESS only if more keys remain         ReplicatedBackend.cc:943
       pos.next_object(); return 0                       PGBackend.cc:998
     (r == -EINPROGRESS ? return : next object)
```

- Replicas build their map the same way, under their own PG lock. That lock
  also blocks the primary's `MOSDRepOp`s, so client writes on the primary wait
  for the replica's scrub item.
- A shallow scrub never yields: up to `osd_shallow_scrub_chunk_max` = 100
  objects of `stat` + `getattrs` per hold.
- The first pass of a chunk is charged for the whole chunk
  (`get_scrub_cost(n)`, which includes the average object size,
  `pg_scrubber.cc:1068-1104`). But a continuation after a yield
  (`PGScrubResched`) is charged `osd_scrub_event_cost` (4 KiB), and it goes on
  through the rest of the chunk in the same way (record 09).
- EC pools use a different yield rule (a read that returns a full stride, per
  shard); the effect for small objects is the same.

## Proposed change

In the `while` loop of `build_scrub_map_chunk`, return `-EINPROGRESS` after
each deep-scrubbed object, or once a byte or time budget is used (for example
4 MiB or 5 ms). The requeue path already exists: it is how objects larger than
one stride are handled today. Cost of the change: the chunk takes more queue
rounds to finish, so a write to an object in the chunk range meets it more
often. While the scrub can still be preempted, such a write preempts it (the
chunk is restarted smaller, `pg_scrubber.cc:1108-1140`); after
`osd_scrub_max_preemptions` (5) the write is blocked
(`write_blocked_by_scrub`) until the chunk is done.

A larger follow-up: writes to the chunk range already preempt the scrub or
wait for it (`write_blocked_by_scrub`), so the reads could run without the PG
lock and the results be merged under it (dropping them if the chunk was
preempted meanwhile).

## How to observe

bpftrace: PG-lock hold time grouped by the item holding it. A uprobe on each
item's `run()` (`PGScrub*`, `PGOpItem`, ...) records the type per thread; the
uretprobe on `PG::lock` and the uprobe on `PG::unlock` give the hold time.
Deep-scrub items should show holds of tens of ms on NVMe.

## Workload

- Fill a PG with 4 MiB objects (`rados bench -b 4194304 write --no-cleanup`).
- Run 4k client writes aimed at that PG, then `ceph pg deep-scrub <pgid>`.
- Compare client p99 with the baseline, and A/B `osd_scrub_chunk_max` 15 vs 3
  as a config-only check of the theory.
