#!/bin/bash
# B13: RocksDBBlueFSVolumeSelector stores rocksdb max_bytes_for_level_multiplier
# (double) in a uint64_t; any value < 1 becomes 0 and update_from_config()'s
# do{}while(true) never terminates once db_total exceeds level0+base.
# OSD mkfs/mount (and ceph-bluestore-tool) spin forever at 100% CPU.
set -u
. ${COMMON:-$(dirname $0)/../common/common.sh}
for mult in 10 0.5; do
  D=$WORK/b13_$mult
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
done
