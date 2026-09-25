#!/bin/bash
# RocksDBBlueFSVolumeSelector stores rocksdb max_bytes_for_level_multiplier
# (double) in a uint64_t; any value < 1 becomes 0 and update_from_config()'s
# do{}while(true) never terminates once db_total exceeds level0+base.
# OSD mkfs/mount (and ceph-bluestore-tool) spin forever at 100% CPU.
set -u
. ${COMMON:-$(dirname $0)/../common/common.sh}
BUG=0
for mult in 10 0.5; do
  D=$WORK/vsel_$mult
  rm -f $D.db.img; truncate -s 4G $D.db.img
  echo "== mkfs with dedicated 4G DB, max_bytes_for_level_multiplier=$mult (60s timeout)"
  start=$(date +%s)
  ( mkosd $D 8G --bluestore-block-db-path $D.db.img --bluestore-block-db-size 0 \
      --bluestore-rocksdb-options-annex=max_bytes_for_level_multiplier=$mult ) &
  pid=$!
  ( sleep 60; kill -9 $pid 2>/dev/null; pkill -9 -f "osd-data $D " 2>/dev/null ) & killer=$!
  wait $pid; rc=$?
  kill $killer 2>/dev/null
  echo "rc=$rc elapsed=$(( $(date +%s) - start ))s  (137/killed at 60s = hang)"
  if [ "$mult" = 10 ] && [ $rc -ne 0 ]; then echo "control failed"; exit 2; fi
  if [ "$mult" = 0.5 ] && [ $rc -eq 137 ]; then BUG=1; fi
done
[ $BUG -eq 1 ] && { echo "BUG: mkfs hangs with max_bytes_for_level_multiplier=0.5"; exit 1; }
echo PASS
