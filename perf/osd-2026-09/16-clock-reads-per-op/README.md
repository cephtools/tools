# About 180 clock reads per client write

| | |
|---|---|
| Area | op tracker, OSD op path, messenger, BlueStore txc |
| Change | small each |
| Expected gain | profile: the vDSO is 3.6% of OSD CPU on 4k writes and 4.8% on 4k reads; the cuts below remove roughly a third of the reads (estimate) |
| Risk | low |
| Status | profile-backed cost; the cuts are not built |

## Summary

In the perf profile (`results/profile-2026-09-25/`, `*.dso-symbol.txt`) the
largest single user-space entry is `[vdso] 0x989`: 3.2% of all OSD CPU on 4k
writes (3.6% for the whole vDSO), 4.3% on 4k random reads (3.0% in
`tp_osd_tp`). perf shows it only as an address; it is taken to be
`clock_gettime`, the only vDSO function the OSD calls often (an inference).
The host's clock source is `tsc`, so each read should be cheap; the cost
comes from the number of reads. Counted in the code for one replicated
write (all 3 OSDs):

| where | fine-grained clock reads |
|---|---|
| messenger: ~9 per received and ~4–5 per sent message, ~12 messages | ~80–90 |
| OSD op path: primary ~20, each replica ~12, each reply handled as an op ~8 | ~55–60 |
| BlueStore: ~13 per transaction (queue, each state change, commit), 3 transactions | ~40 |

About 180 reads for about 20 µs of CPU is ~110 ns per read, more than a TSC
read usually costs; the SRSO mitigation thunks seen in the profile
(`srso_alias_*`) may add to it (inference).

## Proposed change

- `TrackedOp::mark_event(std::string_view, utime_t stamp = ceph_clock_now())`
  (`common/TrackedOp.h:355`): the default argument reads the clock at the call
  site, before `mark_event` checks `if (!state) return;`
  (`common/TrackedOp.cc:604`). Read it inside, after the check.
- Take one `now` per stage and reuse it: `dequeue_op` for `reached_pg`,
  `started` and the dequeue time; `finish_ctx` for `new_repop`;
  `log_op_stats` for `commit_sent`.
- Messenger: `l_msgr_running_recv_time` and `l_msgr_running_fast_dispatch_time`
  cost about 4 monotonic reads per message only to feed counters
  (`ProtocolV2.cc:1537-1555`, `AsyncConnection.cc:389, 500, 746`); derive them
  from the event loop's own measurement, or put them behind an option.
- `check_laggy` (`PrimaryLogPG.cc:854-866`) compares against a read lease
  measured in seconds: a coarse clock with a small margin is enough.
- BlueStore `log_state_latency`: consecutive state changes in one
  `_txc_state_proc` call can share one `now`.
- Coarse clocks are not a fit for the latency counters (1–4 ms resolution).

## How to observe

`perf record` self time of the vDSO `clock_gettime` in `ceph-osd`; `perf probe`
counts of `ceph_clock_now` and `ceph::mono_clock::now` divided by client ops.

## Workload

`rados bench -b 4096 -t 64 write` and `rand` on ramdisk OSDs (most random
reads miss the BlueStore cache).
