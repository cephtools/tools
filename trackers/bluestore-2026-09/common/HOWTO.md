# Running the reproducers

All reproducers were verified on ceph `main` @ **98fb1cf8c58** (2026-09-24),
RelWithDebInfo build, file-backed devices on a rotational virtio disk (host c28).

## gtest reproducers (`test.cc`)
`patches/bluestore-bughunt-tests.patch` adds every `test.cc` of this directory to
the ceph tree (applies cleanly to 98fb1cf8c58):

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
