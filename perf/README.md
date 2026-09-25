# perf

Performance studies: where the time goes on a ceph code path, and which source
changes would give it back. Each study has an index README and one record per
candidate (theory with code references, proposed change, risk, how to observe
it, and the workload that shows it).

- [osd-2026-09](osd-2026-09/) — 13 candidates in the classic OSD path, found by code analysis of v21.3.0; 3 measured so far (2 confirmed, 1 too small to measure).
