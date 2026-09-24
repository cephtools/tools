#!/bin/bash
# ceph-bluestore-tool reshard: failure is printed but the tool exits 0.
set -u
. ${COMMON:-$(dirname $0)/../common/common.sh}
D=$WORK/reshard-exit
mkosd $D $((4*1024*1024*1024)) || exit 1
echo "== current sharding"; $BT --path $D show-sharding
echo "== reshard with an invalid spec (parse error -> -EINVAL)"
$BT --path $D --sharding "m(x) p(3)" reshard > $WORK/reshard.out 2>&1; RC=$?
cat $WORK/reshard.out | tail -3; echo "rc=$RC"
if grep -q "error resharding" $WORK/reshard.out && [ $RC -eq 0 ]; then
  echo "FAIL (bug reproduced: reshard failed but exit status 0)"; exit 1
fi
[ $RC -ne 0 ] && echo "PASS"
