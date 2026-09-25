#!/bin/bash
# Real-workload stress for BlueStore: a 3-OSD vstart cluster runs the QA
# model-checking workload (ceph_test_rados: snapshots, rollback, copy_from,
# append, attrs, omap, watch, deletes; every read is verified) while a thrasher
# kill -9's and restarts OSDs.  Afterwards every OSD is deep-fscked.
#
#   BUILD=<ceph>/build bash workload-thrash.sh <variant> [seconds]
# variants: default | compress | writev2 | ssd | ssd-writev2-compress | legacy64k | ec
set -u
. "$(dirname "$0")/live-common.sh"
V=${1:-default}; SECS=${2:-900}
OUT=${OUT:-/root/bh/thrash-$V-$(date +%H%M%S)}; mkdir -p "$OUT"
opts=("bluestore_block_size = 6442450944" "bluestore_cache_size_hdd = 134217728"
      "bluestore_cache_size_ssd = 134217728" "osd_op_queue = wpq"
      "debug_osd = 1/10" "debug_bluestore = 1/10" "debug_bluefs = 1/10" "debug_rocksdb = 1/5"
      "debug_ms = 0/0" "debug_bdev = 1/5")
case $V in
  default) ;;
  compress) opts+=("bluestore_compression_mode = force" "bluestore_compression_algorithm = lz4"
                   "bluestore_min_alloc_size_hdd = 16384");;
  writev2) opts+=("bluestore_write_v2 = true" "bluestore_min_alloc_size_hdd = 16384");;
  legacy64k) opts+=("bluestore_min_alloc_size_hdd = 65536");;
  ssd) opts+=("bluestore_debug_enforce_settings = ssd");;
  ssd-writev2-compress) opts+=("bluestore_debug_enforce_settings = ssd" "bluestore_write_v2 = true"
                   "bluestore_compression_mode = force" "bluestore_compression_algorithm = snappy");;
  ec) opts+=("bluestore_min_alloc_size_hdd = 16384");;
  *) echo "unknown variant"; exit 2;;
esac

(cd "$BUILD" && ../src/stop.sh >/dev/null 2>&1)
rm -rf "$VSTART_DEST"; mkdir -p "$VSTART_DEST"
args=(); for o in "${opts[@]}"; do args+=(-o "$o"); done
(cd "$BUILD" && MON=1 OSD=3 MDS=0 MGR=1 RGW=0 OSD_POOL_DEFAULT_SIZE=3 \
   ../src/vstart.sh -n -x --without-dashboard "${args[@]}" > "$OUT/vstart.log" 2>&1) \
  || { echo "vstart failed"; tail "$OUT/vstart.log"; exit 2; }
if [ "$V" = ec ]; then
  $C osd erasure-code-profile set k2m1 k=2 m=1 crush-failure-domain=osd >/dev/null
  $C osd pool create p 16 16 erasure k2m1 >/dev/null; $C osd pool set p allow_ec_overwrites true >/dev/null
  ECARG=(--ec-pool); OPS=(--op read 100 --op append 100 --op delete 10 --op snap_create 10 --op snap_remove 10 --op rollback 5 --op setattr 10 --op rmattr 10 --op copy_from 10)
else
  $C osd pool create p 16 >/dev/null; $C osd pool set p size 2 >/dev/null
  ECARG=(); OPS=(--op read 100 --op write 100 --op write_excl 20 --op writesame 10 --op append 30 --op append_excl 10 --op delete 20 --op snap_create 15 --op snap_remove 15 --op rollback 10 --op setattr 20 --op rmattr 10 --op watch 5 --op copy_from 20)
fi
$C osd pool application enable p rados >/dev/null 2>&1

osd_pid() { pgrep -f "ceph-osd -i $1 -c $CEPH_CONF"; }
thrash() {
  while [ -f "$OUT/running" ]; do
    sleep $((120 + RANDOM % 120)); [ -f "$OUT/running" ] || break
    local i=$((RANDOM % 3)) p; p=$(osd_pid $i) || continue
    echo "$(date +%T) kill -9 osd.$i" >> "$OUT/thrash.log"; kill -9 $p
    sleep $((5 + RANDOM % 20))
    (cd "$BUILD" && bin/ceph-osd -i $i -c "$CEPH_CONF") >> "$OUT/thrash.log" 2>&1
    echo "$(date +%T) restarted osd.$i" >> "$OUT/thrash.log"
  done
}
touch "$OUT/running"; if [ "${NOTHRASH:-0}" = 1 ]; then TP=""; else thrash & TP=$!; fi
timeout $((SECS + 600)) "$BIN/ceph_test_rados" --pool p --max-ops 200000 --max-seconds $SECS \
  --objects 300 --max-in-flight 16 --size 4000000 --min-stride-size 40000 --max-stride-size 800000 \
  "${ECARG[@]}" "${OPS[@]}" > "$OUT/test_rados.log" 2>&1
TR=$?; rm -f "$OUT/running"; [ -n "$TP" ] && wait $TP
echo "ceph_test_rados rc=$TR"; tail -3 "$OUT/test_rados.log"
sleep 20; timeout 30 $C health detail 2>/dev/null | head -6
grep -hE "FAILED ceph_assert|Caught signal|_verify_csum bad|missing primary copy|unfound" \
  "$VSTART_DEST"/out/osd.*.log 2>/dev/null | sed -E 's/^\S+ \S+ +-?[0-9]+ //' | sort | uniq -c | sort -rn | head -10
(cd "$BUILD" && ../src/stop.sh >/dev/null 2>&1); sleep 3
for i in 0 1 2; do
  echo "-- deep fsck osd.$i"
  "$BUILD/bin/ceph-bluestore-tool" --path "$VSTART_DEST/dev/osd$i" -c "$CEPH_CONF" fsck --deep 1 2>&1 \
    | grep -E "fsck error|fsck success|fsck status" | sed -E 's/^\S+ \S+ +-?[0-9]+ //' | sort | uniq -c | head -8
done
if [ $TR -ne 0 ] || grep -qE "FAILED ceph_assert|Caught signal|_verify_csum bad" "$VSTART_DEST"/out/osd.*.log 2>/dev/null; then
  cp -r "$VSTART_DEST/out" "$OUT/"; echo "logs kept in $OUT/out"
fi
