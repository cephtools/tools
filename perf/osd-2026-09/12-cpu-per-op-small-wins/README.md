# Small CPU costs per op

| | |
|---|---|
| Area | replicated write path, read path, messenger |
| Change | trivial to small, each |
| Expected gain | each 0.1–2 µs per op (estimates); together visible as OSD CPU per IOP |
| Risk | low |
| Status | code analysis, not measured |

Each item below is small. Together they matter when the OSD is CPU-bound
(small I/O on NVMe).

## Write path (under the PG lock)

| Item | Where | Change |
|---|---|---|
| Log vector deep-copied: `_log_entries` is a `vector&&`, but a named rvalue reference is an lvalue | `ReplicatedBackend.cc:611` | `log_entries(std::move(_log_entries))` |
| Transaction encoded once per replica | `ReplicatedBackend.cc:1181` (`generate_subop`) | encode once in `issue_op`, share the bufferlists |
| Full `pg_stat_t` copied into each `MOSDRepOp` | `ReplicatedBackend.cc:1193-1196` | copy once when no peer is incomplete |
| `ostringstream` + set copy for "waiting for subops from ..." on every op, even with the op tracker off | `ReplicatedBackend.cc:1225-1231` | build it only if the op is tracked |
| `PGTransaction::setattrs` calls `rebuild()` (a memcpy) on the already contiguous OI/SS attrs | `osd/PGTransaction.h:364-373` | rebuild only if not contiguous |

## Read path

| Item | Where | Change |
|---|---|---|
| Two `SharedLRU` lookups per op | `maybe_await_blocked_head` (`PrimaryLogPG.cc:783`), then `get_object_context` | reuse the first result |
| `object_info_t` and `SnapSet` copied twice per op | `OpContext` constructor, then `reset_obs` (`PrimaryLogPG.cc:4294`) | copy once |
| A `PGTransaction` allocated for every read | `PrimaryLogPG.cc:4303` | allocate lazily (many callers assume non-null) |
| `read_wait_aio_lat` sampled even when no aio was issued | `BlueStore::_do_read` | skip when no aio is pending |

## Shared cache lines (every op, every thread)

- `Connection::get_priv()` is called about 4 times per client op (a mutex and
  an atomic on the shared `Session` refcount). Keep one reference in the
  `OpRequest`.
- OpenTelemetry no-op spans: `start_trace`/`add_span` return a copy of one
  global `shared_ptr` (`OSD.cc:7751`, `9938`). Skip the calls when tracing is
  disabled.
- mClock `empty()` takes `data_mtx` 3–4 times per op, while `shard_lock` is
  already held. Keep a plain size counter.
- `can_discard_replica_op` takes the global `pre_publish_lock` and copies the
  next-map pointer for each replica message (`PG.cc:2008`).
- `pg_slots.emplace` may allocate a node that is freed at once when the key
  exists (`OSD.cc:11229`); use `try_emplace`.

## How to observe

- `perf record -g -t <tp_osd_tp tids>`; `perf c2c` for the shared cache lines.
- OSD CPU per IOP: `perf stat -e task-clock -p <osd>` divided by IOPS.
- Upper bound for the counter costs: `perf = false` (restart needed);
  op tracker: `osd_enable_op_tracker = false`.

## Workload

`rados bench -t 64 -b 4096 write` on a size-3 pool, and fio rbd 4k randread
iodepth 32 on a warm image, on a fast store so the OSD is CPU-bound.
