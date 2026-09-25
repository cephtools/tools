# The PG log trim point search walks up to `target` log entries

| | |
|---|---|
| Area | `PeeringState::calc_trim_to_aggressive` |
| Change | a few lines (switch 15 in `common/measurement-switches.patch`) |
| Expected gain | profile: 0.5% of OSD CPU on 4k writes (self time) |
| Risk | low (same result, checked by review and a brute-force comparison) |
| Status | profile-backed; the A/B is running |

## Summary

With the `pglog_hardlimit` flag set (the normal case) every write calls
`calc_trim_to_aggressive`. It returns early until at least
`osd_pg_log_trim_min` (100) entries can be trimmed; then its loop
(`PeeringState.cc:5136-5148`) walks the log from both ends and only stops
once it has passed `target + 1` entries from the newest end, because
`by_n_to_keep` is set only when `i > target`. `target` is
300000 / PGs per OSD, clamped to [250, 10000]: up to 10,000 cold list nodes
per trim batch. The review also found that the walk runs on every write while
the trim point is held back by `pg_committed_to` or `can_rollback_to`.

The perf profile of 4k writes shows `PeeringState::calc_trim_to_aggressive`
at 0.5% self time (`results/profile-2026-09-25/`).

## Proposed change

The loop keeps index `size - target - 1` (counting from `begin()`, the oldest
entry) and trims to index `num_to_trim - 1`; versions grow from `begin()`
towards `end()`, so the result is simply the version at the smaller of the
two indexes (capped by `limit`). Walk only to that index: about
`num_to_trim` (~100) hops instead of up to 10,000.

```cpp
const auto &log = pg_log.get_log().log;
const size_t n = log.size();
if (n <= target)
  return;                              // the loop would not set by_n_to_keep
const size_t keep_idx = n - target - 1;
const size_t idx = num_to_trim == 0 ? 0   // osd_pg_log_trim_max = 0
                 : std::min<size_t>(keep_idx, num_to_trim - 1);
pg_trim_to = std::min(std::next(log.begin(), idx)->version, limit);
```

An independent review checked equivalence case by case and by brute force
(n 0..14, target 0..16, num_to_trim 0..19, 3 limits: 0 mismatches).

## How to observe

`perf record` on the OSDs during 4k writes: self time of
`PeeringState::calc_trim_to_aggressive`. A/B with switch 15 (`osdperf-leg.sh
... 15`).

## Workload

`rados bench -b 4096 -t 64 write` with 100+ PGs per OSD (the log target is
then ≤ 3000 entries per PG; fewer PGs mean longer logs and a longer walk).
