#!/bin/bash
# B10: bluestore_min_alloc_size is declared 'uint' while its _hdd/_ssd siblings
# are 'size'.  'uint' goes through strict_si_cast (decimal SI), so "64K" means
# 64000, not 65536 -> mkfs fails "not power of 2"; the same string works for
# bluestore_min_alloc_size_hdd/_ssd.
set -u
. ${COMMON:-$(dirname $0)/../common/common.sh}
echo "== config parse"
$BIN/ceph-conf -c /dev/null --show-config-value bluestore_min_alloc_size --bluestore_min_alloc_size=64K 2>&1
$BIN/ceph-conf -c /dev/null --show-config-value bluestore_min_alloc_size_hdd --bluestore_min_alloc_size_hdd=64K 2>&1
echo "== mkfs with bluestore_min_alloc_size_hdd=64K (control)"
mkosd $WORK/b10a 2G --bluestore-min-alloc-size-hdd=64K && echo mkfs ok
echo "== mkfs with bluestore_min_alloc_size=64K"
mkosd $WORK/b10b 2G --bluestore-min-alloc-size=64K && echo mkfs ok
grep -m2 -i "power of 2\|min_alloc_size" $WORK/b10b/mkfs.log
