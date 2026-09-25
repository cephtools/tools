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
bluestore fails is part of the evidence (bugs 04, 05, 19).

## shell reproducers (`repro.sh`)
Run as root on a host with a ceph build; they source `common.sh`:

```
BIN=<build>/bin WORK=/tmp/bh COMMON=/path/to/common/common.sh bash repro.sh
```
`common.sh` provides `mkosd <dir> <size> [ceph-osd --mkfs args]`, which creates a
standalone OSD (no monitor needed) with its block file at `<dir>.img`.
