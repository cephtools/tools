# Running the reproducers

All reproducers were verified on a clean ceph `origin/main` @ **8e6a13e7a9a**
(2026-09-24) with only `patches/bluestore-bughunt-tests.patch` applied,
RelWithDebInfo build, file-backed devices on a rotational virtio disk (host c28).
First found on 98fb1cf8c58.

## One-shot verification
```
BUILD=<ceph>/build WORK=/tmp/bh bash common/verify-all.sh        # all
BUILD=<ceph>/build WORK=/tmp/bh bash common/verify-all.sh 01 04  # selected
```
Each reproducer must fail with its bug's signature -> `REPRODUCED`;
bug 03 also runs a v1 control that must pass (`CONTROL-OK`).

## gtest reproducers (`test.cc`)
`patches/bluestore-bughunt-tests.patch` adds every `test.cc` of this directory to
the ceph tree (applies cleanly to 98fb1cf8c58 and 8e6a13e7a9a):

```
cd ceph && git apply /path/to/common/patches/bluestore-bughunt-tests.patch
cd build && ninja ceph_test_objectstore ceph_test_bluefs unittest_hybrid_allocator
mkdir -p /tmp/st && cd /tmp/st
# run ONE test per process: several reproducers crash the process on purpose
<build>/bin/ceph_test_objectstore --plugin_dir=<build>/lib --gtest_filter='*/<Suite>.<Test>/*'
<build>/bin/ceph_test_bluefs --gtest_filter='BlueFS_wal.bughunt_*'
<build>/bin/unittest_hybrid_allocator --gtest_filter='*expand_after_spillover*'
```
Each test PASSES on fixed code and FAILS / aborts on 98fb1cf8c58.
`--plugin_dir` is needed so compressor plugins load (bug 13).
Parameterized StoreTest cases run for memstore too; memstore passing while
bluestore fails is part of the evidence (bug 04).

## shell reproducers (`repro.sh`)
Run as root on a host with a ceph build; they source `common.sh`:

```
BIN=<build>/bin WORK=/tmp/bh COMMON=/path/to/common/common.sh bash repro.sh
```
`common.sh` provides `mkosd <dir> <size> [ceph-osd --mkfs args]`, which creates a
standalone OSD (no monitor needed) with its block file at `<dir>.img`.

## Filing on tracker.ceph.com
tracker.ceph.com is Redmine; BlueStore bugs go to project **bluestore** (id 38),
tracker **Bug**. Descriptions use **Textile** (`<pre>` blocks, `@code@`), not Markdown.
Fields used by maintainers on recent BlueStore bugs: Severity (custom field 4:
"2 - major" / "3 - minor"), Regression (13: 0/1), Backport (2, set by maintainers),
Affected Versions (9), Pull request ID (21, set when a fix is posted).

1. Generate the drafts (Subject + Textile body + API payload):
   `python3 common/to-tracker.py NN-*/` -> `NN-*/tracker.textile`, `NN-*/tracker.json`.
2. Either paste `tracker.textile` into https://tracker.ceph.com/projects/bluestore/issues/new
   (Subject = first line, Severity/Regression from the header line), or use the API:
   ```
   REDMINE_API_KEY=<key from /my/account> bash common/file-tracker.sh NN-slug/          # dry run
   REDMINE_API_KEY=<key>                  bash common/file-tracker.sh NN-slug/ --post   # file it
   ```
   The new issue URL is saved in `NN-slug/TRACKER`; the script refuses to file a record twice.
3. When a fix PR is posted, put its number in "Pull request ID" and add
   `Fixes: https://tracker.ceph.com/issues/<id>` to the commit message.

## Live-OSD reproductions
`common/live-scenarios.sh <ids>` starts a fresh 1-OSD vstart cluster per scenario
(`VSTART_DEST`, default /root/bh/vs) and triggers the bug with real client I/O
(librados python bindings from `<build>/lib/cython_modules`) and admin commands only.
Scenarios: 02, 03, 04, 12, 13, 15; bug 01 has its own `01-*/live-osd-repro.sh`.
```
BUILD=<ceph>/build bash common/live-scenarios.sh 02 03 04 12 13 15
BUILD=<ceph>/build bash 01-online-expand-label-not-reserved/live-osd-repro.sh
```
Needs `ninja vstart-base rados` in addition to the binaries above.
