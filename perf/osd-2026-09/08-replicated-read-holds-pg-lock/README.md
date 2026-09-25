# A replicated read holds the PG lock while it waits for the device

| | |
|---|---|
| Area | read path (`PrimaryLogPG::do_read`, `ReplicatedBackend::objects_read_sync`) |
| Change | large (async read); small (batch reads of one op) |
| Expected gain | latency of other ops on a hot PG when reads miss the cache |
| Risk | high for the async read |
| Status | code analysis, not measured |

## Summary

In a replicated pool a read that misses the BlueStore cache runs
`objects_read_sync` in the `tp_osd_tp` worker with the PG lock held, for the
whole device time: 1.5 ms in the post's §4.1 trace, 97 ms in one run. Every
other op of that PG waits.

## Theory

```
 do_read                                          PrimaryLogPG.cc:5934
   objects_read_sync                              6020, ReplicatedBackend.cc:279
     BlueStore::read                              BlueStore.cc:12759
       c->lock (shared)                           12779   held across the wait
       _do_read ... aio_submit, aio_wait          13215
```

- RBD reads use `do_sparse_read` (6057): `fiemap` then `readv`, also
  synchronous.
- If the worker is the shard's commit owner (record 01), the commits of every
  PG in the shard wait too.
- There is no async read for replicated pools:
  `ReplicatedBackend::objects_read_async` aborts
  (`ReplicatedBackend.cc:315`). It was removed as unused in `0cd73313581`
  (2017), not rejected as a design. EC pools already read asynchronously.

## Proposed change

- Large: reuse EC's `pending_async_reads`. Run the store read on a helper
  thread and finish the op from a PG queue item. The catch: writers take
  `c->lock` exclusively in `_txc_add_transaction` (`BlueStore.cc:16239`)
  while holding the PG lock, so a write would still wait for an in-flight read
  of the same collection. This needs a read that does not hold `c->lock`
  across the I/O (pinned extents, or an `AioContext` callback,
  `KernelDevice.cc:750`).
- Small: when one op has several READ sub-ops on one object, merge them into
  one `readv` in `do_osd_ops`, so they cost one device round trip instead of N
  (RGW and CephFS multi-extent reads).

## How to observe

- bpftrace: PG-lock wait histogram (uprobe/uretprobe on `PG::lock`) while
  reads miss the cache.
- `op_w_latency` of a PG while reads to the same PG miss the cache.

## Workload

fio rbd 70/30 randrw, 16k, iodepth 32, on a small image with a cold cache
(`ceph tell osd.N cache drop`); or `rados bench rand` and `rados bench write`
at once on the same pool.
