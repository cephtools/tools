#!/bin/bash
# fsck/repair vs. an undecodable deferred-txn record (PREFIX_DEFERRED "L").
#  - regular fsck prints "fsck error: failed to decode deferred txn" but does
#    NOT count it -> returns 0 / "fsck success" / exit 0
#  - repair (and deep fsck) run _deferred_replay() before the check, which
#    fails with -EIO -> repair aborts, the designed "remove undecodable
#    deferred record" repair in _fsck_on_open is unreachable
#  - mount (OSD start) fails with EIO  => fsck says healthy, OSD cannot start,
#    and repair cannot fix it.
set -u
. ${COMMON:-$(dirname $0)/../common/common.sh}
D=$WORK/fsck-deferred
KV="$BIN/ceph-kvstore-tool"
mkosd $D $((4*1024*1024*1024)) || exit 1

echo "== baseline fsck"
$BT fsck --path $D; echo "rc=$?"

echo "== inject 1-byte (undecodable) value under L/zzzz"
printf 'x' > $WORK/garbage.bin
$KV -c $CONF bluestore-kv $D set L zzzz in $WORK/garbage.bin || { echo "inject failed"; exit 2; }
$KV -c $CONF bluestore-kv $D list L 2>/dev/null | head

echo "== regular fsck (must NOT report success)"
$BT fsck --path $D > $WORK/fsck-deferred.out 2>&1; FSCK_RC=$?
cat $WORK/fsck-deferred.out | tail -5
echo "fsck rc=$FSCK_RC"

echo "== repair (should remove the bad record and succeed)"
$BT repair --path $D > $WORK/repair-deferred.out 2>&1; REPAIR_RC=$?
tail -5 $WORK/repair-deferred.out; echo "repair rc=$REPAIR_RC"

echo "== mount attempt via ceph-objectstore-tool (OSD start equivalent)"
if [ -x $BIN/ceph-objectstore-tool ]; then
  $BIN/ceph-objectstore-tool --no-mon-config --data-path $D --op list 2>&1 | tail -3
fi

FAIL=0
if [ $FSCK_RC -eq 0 ] && grep -q "failed to decode deferred txn" $WORK/fsck-deferred.out; then
  echo "BUG: fsck reported the undecodable deferred txn but exited 0 (fsck success)"
  FAIL=1
fi
if [ $REPAIR_RC -ne 0 ]; then
  echo "BUG: repair cannot fix undecodable deferred txn (rc=$REPAIR_RC)"
  FAIL=1
fi
[ $FAIL -eq 0 ] && echo "PASS" || echo "FAIL"
exit $FAIL
