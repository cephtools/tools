#!/bin/bash
# Run every reproducer in trackers/bluestore-2026-09 and check that each one
# fails with the signature of its bug (not just "some failure").
#
# usage (as root, from anywhere):
#   BUILD=<ceph>/build WORK=/tmp/bh bash verify-all.sh [id ...]
# The ceph tree must have common/patches/bluestore-bughunt-tests.patch applied
# and ceph-osd ceph-conf ceph-bluestore-tool ceph-kvstore-tool
# ceph-objectstore-tool ceph_test_objectstore ceph_test_bluefs
# unittest_hybrid_allocator ceph_lz4 built.
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
BUILD=${BUILD:-/root/git/ceph/ceph/build}
export BIN=$BUILD/bin
export WORK=${WORK:-/root/bh}
export COMMON=$HERE/common/common.sh
OUT=${OUT:-$WORK/verify-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT" "$WORK/st"
SUMMARY=$OUT/summary.txt
: > "$SUMMARY"

OS="$BIN/ceph_test_objectstore --plugin_dir=$BUILD/lib"
BF="$BIN/ceph_test_bluefs"
HY="$BIN/unittest_hybrid_allocator"

# run <id> <label> <timeout> <cmd...> -- <regex that must match>
# run one gtest process in a scratch dir, grep its output for the signature
run() {
  local id=$1 label=$2 to=$3; shift 3
  local cmd=() re
  while [ "$1" != "--" ]; do cmd+=("$1"); shift; done; shift; re=$1
  local f=$OUT/$id-$label.out
  ( cd "$WORK/st" && rm -rf ./*.test_temp_dir* ceph_test_bluefs.tmp.* && \
    timeout "$to" "${cmd[@]}" > "$f" 2>&1 ); local rc=$?
  if grep -qE -- "$re" "$f"; then
    printf '%s\t%-40s\tREPRODUCED\trc=%s\n' "$id" "$label" "$rc" | tee -a "$SUMMARY"
  else
    printf '%s\t%-40s\tNOT-REPRODUCED\trc=%s\n' "$id" "$label" "$rc" | tee -a "$SUMMARY"
  fi
}
# control: must pass
ctl() {
  local id=$1 label=$2 to=$3; shift 3
  local f=$OUT/$id-$label.out
  ( cd "$WORK/st" && rm -rf ./*.test_temp_dir* && timeout "$to" "$@" > "$f" 2>&1 ); local rc=$?
  if [ $rc -eq 0 ] && grep -q "PASSED" "$f"; then
    printf '%s\t%-40s\tCONTROL-OK\trc=%s\n' "$id" "$label" "$rc" | tee -a "$SUMMARY"
  else
    printf '%s\t%-40s\tCONTROL-FAILED\trc=%s\n' "$id" "$label" "$rc" | tee -a "$SUMMARY"
  fi
}
sh_() {  # sh_ <id> <label> <timeout> <script> -- <regex>
  local id=$1 label=$2 to=$3 s=$4; shift 5; local re=$1
  run "$id" "$label" "$to" bash "$HERE/$s" -- "$re"
}
bs() { echo "GetParam\(\) = \"bluestore\""; }

SEL="$*"
sel() { [ -z "$SEL" ] && return 0; for w in $SEL; do [ "$w" = "$1" ] && return 0; done; return 1; }

sel 01 && run 01 OnlineExpandReservesNewLabel 1800 $OS --gtest_filter='*/MultiLabelTest.OnlineExpandReservesNewLabel/*' -- 'object data overwrote the bdev label at 1G|objects corrupted by label write'
sel 02 && run 02 expand_after_spillover 300 $HY --gtest_filter='*expand_after_spillover*' -- 'bytes free in both tree and bitmap'
if sel 03; then
  ctl 03 DeferredReuseRaceV1-control 600 $OS --gtest_filter='*/StoreTestSpecificAUSize.DeferredReuseRaceV1/1'
  run 03 DeferredReuseRaceV2 600 $OS --gtest_filter='*/StoreTestSpecificAUSize.DeferredReuseRaceV2/1' -- 'Which is: -5'
fi
if sel 04; then
  for t in OmapRmKeyRangeSeesSameTxnKeys OmapClearSeesSameTxnKeys OmapCloneSeesSameTxnKeys OmapRemoveSeesSameTxnKeys; do
    run 04 $t 600 $OS --gtest_filter="*/StoreTest.$t/*" -- "FAILED  \] .*$t.*$(bs)"
  done
fi
sel 05 && run 05 RenameAcrossHashKeepsOmap 600 $OS --gtest_filter='*/StoreTest.RenameAcrossHashKeepsOmap/*' -- 'omap lost by rename across hash'
sel 06 && run 06 CloneRangeShiftedWithWritingBuffers 600 $OS --gtest_filter='*/StoreTest.CloneRangeShiftedWithWritingBuffers/*' -- 'served stale/wrong data from cache'
sel 07 && run 07 BluestoreRepairMisrefIntoFalseFree 600 $OS --gtest_filter='*/StoreTestSpecificAUSize.BluestoreRepairMisrefIntoFalseFree/1' -- 'victim object C was overwritten by repair'
sel 08 && run 08 BluestoreRepairSharedBlobMultiPextent 600 $OS --gtest_filter='*/StoreTestSpecificAUSize.BluestoreRepairSharedBlobMultiPextent/1' -- 'ref_map.ref_map.size\(\)'
sel 09 && sh_ 09 repro.sh 900 09-fsck-ignores-undecodable-deferred/repro.sh -- 'BUG: fsck reported the undecodable deferred txn but exited 0'
sel 10 && run 10 bughunt_envmode_ino_reuse 600 $BF --gtest_filter='BlueFS_wal.bughunt_envmode_ino_reuse_stale_envelopes' -- 'new WAL returns data of a deleted WAL'
sel 11 && sh_ 11 repro.sh 600 11-vselector-level-multiplier-hang/repro.sh -- 'BUG: mkfs hangs with max_bytes_for_level_multiplier=0.5'
sel 12 && run 12 ZeroMaxBlobSizeWriteV2 300 $OS --gtest_filter='*/StoreTestSpecificAUSize.ZeroMaxBlobSizeWriteV2/1' -- 'Floating point exception'
sel 13 && run 13 PoolCompressionAlgorithmNoneHonored 300 $OS --gtest_filter='*/StoreTestSpecificAUSize.PoolCompressionAlgorithmNoneHonored/1' -- 'pool compression_algorithm=none ignored'
sel 14 && sh_ 14 repro.sh 300 14-min-alloc-size-uint-units/repro.sh -- '^64000$'
sel 15 && run 15 SmallWriteNear4GiBShardedOnode 600 $OS --gtest_filter='*/StoreTestSpecificAUSize.SmallWriteNear4GiBShardedOnode/1' -- 'FAILED ceph_assert\(last >= start\)'
sel 16 && sh_ 16 repro.sh 300 16-bluefs-import-segfault/repro.sh -- 'exit=139'
if sel 17; then
  run 17 revert_wal_to_plain_skips_db_dir 900 $BF --gtest_filter='BlueFS_wal.bughunt_revert_wal_to_plain_skips_db_dir' -- "left an envelope-mode WAL in 'db' untouched"
  run 17 revert_wal_to_plain_asserts_with_db_wal 900 $BF --gtest_filter='BlueFS_wal.bughunt_revert_wal_to_plain_asserts_with_db_wal' -- 'FAILED ceph_assert\(!log.uses_envelope_mode\)'
fi
sel 19 && run 19 RemoveMissingCollectionENOENT 300 $OS --gtest_filter='*/StoreTest.RemoveMissingCollectionENOENT/*' -- 'Segmentation fault'
sel 20 && sh_ 20 repro.sh 300 20-reshard-failure-exit-zero/repro.sh -- 'bug reproduced: reshard failed but exit status 0'
sel 21 && sh_ 21 repro.sh 600 21-fsck-read-bytes-cap-zero-hang/repro.sh -- 'bug reproduced: deep fsck never terminates'
if sel 22; then
  sh_ 22 repro.sh 900 22-freelist-blocks-per-key-unvalidated/repro.sh -- 'FAILED ceph_assert\(n < _len\)'
  run 22 FreelistBlocksPerKeyNonPow2 900 $OS --gtest_filter='*/StoreTestSpecificAUSize.FreelistBlocksPerKeyNonPow2/1' -- 'FAILED ceph_assert\(first_key == last_key\)'
fi
sel 23 && sh_ 23 repro.sh 600 23-bluefs-alloc-size-non-pow2-abort/repro.sh -- 'non-pow2 BlueFS alloc unit aborts'
sel 24 && run 24 MaxAllocSizeIgnored 600 $OS --gtest_filter='*/StoreTestSpecificAUSize.MaxAllocSizeIgnored/1' -- 'bluestore_max_alloc_size=64K ignored'

echo "== summary: $SUMMARY"
cat "$SUMMARY"
