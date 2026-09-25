#!/bin/bash
# non-power-of-2 bluefs_shared_alloc_size / bluefs_alloc_size -> allocator assert
set -u
. ${COMMON:-$(dirname $0)/../common/common.sh}
SZ=$((8*1024*1024*1024))
fail=0

check() {  # check <name> <dir> <mkosd rc>
  local n=$1 D=$2 rc=$3
  if grep -a -q "Caught signal\|FAILED ceph_assert" $D/mkfs.log 2>/dev/null; then
    echo "  [$n] mkfs CRASHED:"
    grep -a -m3 "FAILED ceph_assert\|Caught signal\|In function" $D/mkfs.log | sed 's/^/    /'
    return 1
  fi
  if [ $rc -ne 0 ]; then echo "  [$n] mkfs refused cleanly (rc=$rc)"; return 0; fi
  timeout 300 $BT --path $D fsck > $D/fsck.out 2>&1 || { echo "  [$n] fsck rc!=0"; tail -2 $D/fsck.out; return 1; }
  echo "  [$n] mkfs+fsck ok"; return 0
}

echo "== control (defaults)"
D=$WORK/bfa-ctl; mkosd $D $SZ >/dev/null 2>&1; check control $D $? || { echo "control failed"; exit 2; }

echo "== single device, bluefs_shared_alloc_size=96K (multiple of 4K min_alloc, not pow2)"
D=$WORK/bfa-shared; mkosd $D $SZ --bluestore-min-alloc-size=4096 --bluefs-shared-alloc-size=96K >/dev/null 2>&1
check shared96K $D $? || fail=1

echo "== dedicated DB, bluefs_alloc_size=1536K"
D=$WORK/bfa-db; rm -f $D.db
mkosd $D $SZ --bluestore-block-db-path=$D.db --bluestore-block-db-create=true \
  --bluestore-block-db-size=$((2*1024*1024*1024)) --bluefs-alloc-size=1536K >/dev/null 2>&1
check db1536K $D $? || fail=1

if [ $fail -ne 0 ]; then
  echo "FAIL (bug reproduced: non-pow2 BlueFS alloc unit aborts instead of being rejected)"
  exit 1
fi
echo "PASS"
