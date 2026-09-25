#!/bin/bash
# End-to-end reproduction of bug 01 on a running OSD (vstart), using only the
# real admin command and RADOS clients:
#   ceph tell osd.0 bluestore bluefs-bdev-expand   (online expand, main only)
#
# usage (as root, from anywhere):  BUILD=<ceph>/build bash live-osd-repro.sh
set -u
BUILD=${BUILD:-/root/git/ceph/ceph/build}
export VSTART_DEST=${VSTART_DEST:-/root/bh/vs}
NOBJ=${NOBJ:-350}                 # 350 x 4 MiB = 1.4 GiB, crosses the 1 GiB label
OBJ=$((4 << 20))
cd "$BUILD" || exit 2
rm -rf "$VSTART_DEST"; mkdir -p "$VSTART_DEST"
export CEPH_CONF=$VSTART_DEST/ceph.conf
C="$BUILD/bin/ceph"
R="$BUILD/bin/rados -p p"
BLK=$VSTART_DEST/dev/osd0/block
DATA=$VSTART_DEST/objdata; mkdir -p "$DATA"

label_at_1g() {   # print the label magic found at offset 1 GiB (or <none>)
  local m; m=$(dd if="$BLK" bs=4096 skip=262144 count=1 2>/dev/null | head -c 22)
  [ "$m" = "bluestore block device" ] && echo "label present" || echo "no label (data: $(dd if="$BLK" bs=4096 skip=262144 count=1 2>/dev/null | head -c 16 | od -An -tx1 | tr -s ' '))"
}

echo "== start 1-OSD vstart cluster, main device 900 MiB"
MON=1 OSD=1 MDS=0 MGR=1 RGW=0 OSD_POOL_DEFAULT_SIZE=1 ../src/vstart.sh -n -x \
  --without-dashboard -o "bluestore_block_size = 943718400" > "$VSTART_DEST/vstart.log" 2>&1 \
  || { echo "vstart failed"; tail -20 "$VSTART_DEST/vstart.log"; exit 2; }
$C osd pool create p 8 >/dev/null 2>&1; $C osd pool set p size 1 --yes-i-really-mean-it >/dev/null 2>&1
echo "block size: $(stat -c %s "$BLK")"

echo "== grow backing file to 3 GiB, online expand"
truncate -s 3G "$BLK"
$C tell osd.0 bluestore bluefs-bdev-expand 2>&1 | tail -4
echo "offset 1G after expand: $(label_at_1g)"

echo "== write $NOBJ x 4 MiB random objects via rados"
: > "$DATA/md5"
for i in $(seq 1 $NOBJ); do
  head -c $OBJ /dev/urandom > "$DATA/in"
  echo "obj$i $(md5sum < "$DATA/in" | cut -c1-32)" >> "$DATA/md5"
  timeout 60 $R put "obj$i" "$DATA/in" || echo "put obj$i failed"
done
echo "offset 1G after writes: $(label_at_1g)"

echo "== grow to 3.5 GiB, second online expand (rewrites labels at all valid locations)"
truncate -s 3584M "$BLK"
$C tell osd.0 bluestore bluefs-bdev-expand 2>&1 | tail -2
echo "offset 1G after 2nd expand: $(label_at_1g)"

echo "== read back all objects"
bad=0; eio=0
while read -r name sum; do
  if ! timeout 60 $R get "$name" "$DATA/out" 2>"$DATA/err"; then
    eio=$((eio+1)); echo "  $name: get failed: $(tail -1 "$DATA/err")"
  elif [ "$(md5sum < "$DATA/out" | cut -c1-32)" != "$sum" ]; then
    bad=$((bad+1)); echo "  $name: content mismatch"
  fi
done < "$DATA/md5"
echo "read errors=$eio mismatches=$bad (of $NOBJ)"
timeout 30 $C health detail 2>/dev/null | head -8
grep -h "_verify_csum bad" "$VSTART_DEST"/out/osd.0.log 2>/dev/null | head -3 | sed -E 's/^\S+ \S+ +-?[0-9]+ //' | cut -c1-200

echo "== stop cluster, fsck"
../src/stop.sh >/dev/null 2>&1
sleep 3
"$BUILD/bin/ceph-bluestore-tool" --path "$VSTART_DEST/dev/osd0" -c "$CEPH_CONF" fsck 2>&1 \
  | grep -E "fsck error|fsck success|fsck status" | sed -E 's/^\S+ \S+ +-?[0-9]+ //' | head -8

if [ $eio -gt 0 ] || [ $bad -gt 0 ]; then
  echo "BUG REPRODUCED on a live OSD: object data lost after online expand"; exit 1
fi
echo "no data loss observed"
