#!/bin/bash
# bluestore_freelist_blocks_per_key unvalidated -> SIGFPE / assert / broken bitmap freelist
set -u
. ${COMMON:-$(dirname $0)/../common/common.sh}
SZ=$((4*1024*1024*1024))
fail=0

try() {  # try <blocks_per_key>
  local v=$1 D=$WORK/fl-bpk-$1
  echo "== blocks_per_key=$v (bitmap freelist: allocation_from_file=false)"
  mkosd $D $SZ --bluestore-allocation-from-file=false \
      --bluestore-freelist-blocks-per-key=$v >/dev/null 2>&1; local rc=$?
  if grep -a -q -m1 "Caught signal\|FAILED ceph_assert" $D/mkfs.log 2>/dev/null; then
    echo "  mkfs CRASHED:"; grep -a -m2 "Caught signal\|FAILED ceph_assert\|in function" $D/mkfs.log | sed 's/^/    /'
    return 1
  fi
  if [ $rc -ne 0 ]; then echo "  mkfs refused cleanly (rc=$rc)"; return 0; fi
  timeout 300 $BT --path $D fsck --bluestore-allocation-from-file=false \
      --log-file $D/fsck.log > $D/fsck.out 2>&1; rc=$?
  tail -1 $D/fsck.out | sed 's/^/  fsck: /'
  if [ $rc -ne 0 ] || grep -a -q "Caught signal\|FAILED ceph_assert" $D/fsck.log; then
    grep -a -m3 "fsck error\|Caught signal\|FAILED ceph_assert" $D/fsck.log $D/fsck.out | sed 's/^/    /'
    return 1
  fi
  echo "  mkfs+fsck clean"; return 0
}

try 128 || { echo "control (128) failed, cannot judge"; exit 2; }
for v in 0 4 96; do try $v || fail=1; done

if [ $fail -ne 0 ]; then
  echo "FAIL (bug reproduced: invalid bluestore_freelist_blocks_per_key crashes or corrupts freelist)"
  exit 1
fi
echo "PASS"
