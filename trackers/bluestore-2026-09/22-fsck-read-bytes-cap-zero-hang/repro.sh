#!/bin/bash
# bluestore_fsck_read_bytes_cap=0 -> deep fsck infinite loop (BlueStore.cc ~11040)
set -u
. ${COMMON:-$(dirname $0)/../common/common.sh}
D=$WORK/fsck-cap0
mkosd $D $((4*1024*1024*1024)) || exit 2

echo "== control: fsck --deep 1 with default cap"
timeout 300 $BT --path $D fsck --deep 1 > $WORK/fsck-cap-ctl.out 2>&1; RC0=$?
tail -2 $WORK/fsck-cap-ctl.out; echo "rc=$RC0"
[ $RC0 -eq 0 ] || { echo "control fsck failed, cannot judge"; exit 2; }

echo "== fsck --deep 1 with bluestore_fsck_read_bytes_cap=0 (timeout 120s)"
start=$(date +%s)
timeout 120 $BT --path $D fsck --deep 1 --bluestore_fsck_read_bytes_cap=0 \
  > $WORK/fsck-cap0.out 2>&1; RC=$?
echo "rc=$RC after $(( $(date +%s) - start ))s"
if [ $RC -eq 124 ]; then
  echo "evidence: 5s run with debug_bluestore=20 (expect endless '_do_read 0x0~0' lines)"
  timeout 5 $BT --path $D fsck --deep 1 --bluestore_fsck_read_bytes_cap=0 \
    --log-file $WORK/fsck-cap0.log --debug-bluestore 20 >/dev/null 2>&1
  grep -a -c "_do_read 0x0~0 " $WORK/fsck-cap0.log; rm -f $WORK/fsck-cap0.log
  echo "FAIL (bug reproduced: deep fsck never terminates with cap=0)"
  exit 1
fi
echo "PASS (deep fsck finished rc=$RC)"
