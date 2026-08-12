# ceph tracing tools

bpftrace-based latency tracing for the fio → librbd → OSD → BlueStore stack.
Each tool answers one question; together they walk a slow IO from the client
down to the storage layer that caused it.

| Tool | Where it runs | Question it answers |
|------|---------------|---------------------|
| `fio-rbd-lat.sh` | fio client | Which IOs were slow, and was the time spent in ceph or in fio? |
| `oplat.bt` | OSD node | How long did the OSD take per request (read/write/other)? |
| `wlat.bt` | OSD node | Which BlueStore stage of the write transaction ate the time? |

## Requirements

- `bpftrace`, `binutils` (`nm`, `readelf`), `gdb`
- Debug symbols for the traced binaries:
  - `fio-rbd-lat.sh` resolves them itself (build-id lookup, debuginfod
    download, or distro package install — `dnf debuginfo-install fio
    fio-engine-rbd` on Fedora, `fio-dbgsym` from ddebs on Ubuntu).
  - `oplat.bt` / `wlat.bt` attach to mangled C++ symbols in `ceph-osd`;
    a dev build or a binary with symbols is needed.

## fio-rbd-lat.sh — client-side: find the slow IO, name the object

Traces two events per slow IO, correlated by `io_u` pointer:

- `rbd_cmpl`: `fio_rbd_queue()` → `_fio_rbd_finish_aiocb()` — pure
  librbd/cluster time, stamped in librbd's callback thread.
- `clat`: fio's own completion latency from `add_clat_sample()` —
  includes fio's reap delay.

`clat ≈ rbd_cmpl` → the latency is in ceph. `clat ≫ rbd_cmpl` → the IO
finished fast but waited for fio's event loop.

```
./fio-rbd-lat.sh [threshold_us] [fio_path] [rbd_engine_path]
    # defaults: 20000 us, fio from PATH, engine auto-detected
RESOLVE_ONLY=1 ./fio-rbd-lat.sh     # preflight: print resolved probes, don't attach
NO_INSTALL=1   ./fio-rbd-lat.sh     # never auto-install debug packages
RBD_OBJ_SIZE=$((1<<order)) ./fio-rbd-lat.sh   # image with non-default object size
```

```
TIME     COMM             TID   EVENT    DDIR       OFFSET   LEN  LAT(us)           OBJECT  OBJ_OFF
11:21:36 io_context_pool  8525  rbd_cmpl write  47535063040  4096   20334 0000000000002c45  1015808
11:21:36 fio              8535  clat     write  47535063040  4096   20345 0000000000002c45  1015808
```

The OBJECT column is the 16-digit hex suffix of the RADOS object; the full
name is `<block_name_prefix>.<OBJECT>` with the prefix from
`rbd info <pool>/<image>`. From there:

```
ceph osd map <pool> rbd_data.<id>.<OBJECT>    # -> PG and OSDs that served it
```

Ctrl-C prints `@rbd_lat_us` / `@clat_us` histograms over all IOs, not just
the ones above the threshold.

Works with distro-shipped fio on Fedora (external `fio-rbd.so`) and
Ubuntu/Debian (rbd engine built into the binary), and with self-built fio.
All build-dependent facts — symbol addresses, `struct io_u` field offsets,
and the `add_clat_sample` ABI change in fio 3.39 — are resolved at runtime
per binary. Requires clat accounting (no `disable_clat=1` / `gtod_reduce=1`).

## oplat.bt — OSD-side: per-request latency

Spans `OpTracker::create_request` → `PrimaryLogPG::log_op_stats`, the exact
endpoint of the OSD's `op_w_latency` / `op_r_latency` counters. Ops are
classified by the `log_op_stats` byte arguments: writes, reads, other
(metadata-only). Correlation is a single ABI-derived key (the sret return
slot of `create_request`), so there are no struct offsets to re-derive per
build.

```
bpftrace oplat.bt <path-to-ceph-osd>
# run workload, Ctrl-C for per-type histograms and averages
```

## wlat.bt — BlueStore: write transaction stage breakdown

Follows each `TransContext` through the state machine and reports one
histogram per stage, plus the client-visible total and the OSD-level op
span for cross-checking:

```
queue_transactions   t0   prep:      decode, allocate, checksum (CPU)
_txc_state_proc      t1   data_io:   aio_write to the data device
_txc_finish_io       t2   kv_queued: waiting for the kv_sync batch
_txc_apply_kv        t3   kv_commit: rocksdb sync commit + callback
_txc_committed_kv    t4
```

```
bpftrace wlat.bt <path-to-ceph-osd>              # histograms on Ctrl-C
bpftrace wlat.bt -- <path-to-ceph-osd> --per-txc # one line per commit
```

A mixed direct/deferred workload shows up as bimodal `data_io` and
`kv_queued` histograms: milliseconds for direct writes (the data-device
flush lands in `kv_queued`), microseconds for deferred.

## Workflow: from a slow fio IO to the guilty layer

1. `fio-rbd-lat.sh 20000` on the client → slow IO with OBJECT name; the
   paired lines tell you the time is inside ceph.
2. `ceph osd map` on the object → the serving OSD.
3. `oplat.bt` on that OSD → confirm the op was slow server-side (client
   latency minus this span = network + messenger).
4. For writes, `wlat.bt` on the OSD → which BlueStore stage to blame.
