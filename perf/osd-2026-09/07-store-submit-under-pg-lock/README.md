# BlueStore issues the data write (io_submit) while the PG lock is held

| | |
|---|---|
| Area | BlueStore `queue_transactions`, called under the PG lock |
| Change | medium |
| Expected gain | PG-lock hold time per write; removes device-submit stalls from the PG |
| Risk | medium |
| Status | code analysis, not measured; one lab observation |

## Summary

The OSD calls `BlueStore::queue_transactions` from the `tp_osd_tp` worker
while holding the PG lock. On an SSD-configured OSD a small overwrite is a
direct write, and BlueStore calls `io_submit()` in that same thread. Whatever
`io_submit` costs, the PG pays inside its lock.

In the post's write trace (§4.2.6), one replica spent 2.65 ms in
`queue_transactions` in every run, against about 0.12–0.15 ms on the other two
OSDs. That replica's OSD sits on a QEMU-emulated NVMe disk. The theory, **not
yet checked**, is that `io_submit` is slow on that device.

## Theory

```
 queue_transactions                                   BlueStore.cc:15980
   _txc_add_transaction
     c->lock (unique)                                 16239
     get_onode      miss -> sync db->get              16243 -> 5421
     _do_write_big: a full 16K overwrite is not deferrable -> new allocation
     _do_alloc_write                                  17290
       prefer_deferred_size = 0 on ssd -> bdev->aio_write      17551-17571
   _txc_state_proc  STATE_PREPARE
     _txc_aio_submit -> bdev->aio_submit              14651, KernelDevice.cc:1001
       io_submit()                                    blk/aio/aio.cc:43
       EAGAIN -> usleep and retry                     blk/aio/aio.cc:18-68
```

- On an HDD-configured OSD (`prefer_deferred_size` 64K) the same write is
  deferred and issues no data I/O in the caller.
- A second cost is on the replica side: the primary loads the object's onode
  earlier (`get_object_context`), but a replica applies the primary's
  transaction without loading the object first. An onode cache miss there
  becomes a synchronous RocksDB read under the replica's PG lock.

## Proposed change

- Submit the aio outside the PG lock: hand the txc to a small per-shard
  submitter thread, or submit after `pg->unlock()`. Completion order is still
  enforced by `osr->q` in `_txc_finish_io`, and the `IOContext` belongs to one
  txc only.
- Load the replica's onode before taking the PG lock (for example a
  `prefetch_onodes()` call when the `MOSDRepOp` is queued).

## How to observe

```
bpftrace -e '
tracepoint:syscalls:sys_enter_io_submit /comm == "tp_osd_tp"/ { @s[tid] = nsecs; }
tracepoint:syscalls:sys_exit_io_submit /@s[tid]/ {
    @io_submit_us[pid] = hist((nsecs - @s[tid]) / 1000); delete(@s[tid]); }'
```

Also compare, per OSD, the BlueStore counters `state_prepare_lat`,
`txc_submit_lat` and `onode_misses`, and `ceph osd metadata N` (rotational,
device type).

## Workload

4k randwrite at iodepth 16–64 aimed at a few PGs (for example an rbd image in
a 1-PG pool), so the PG lock is the bottleneck. Compare per-PG IOPS and
`op_w_latency`.
