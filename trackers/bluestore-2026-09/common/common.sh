# common helpers for the bluestore-2026-09 repro scripts (run as root; override BIN/WORK)
BIN=${BIN:-/root/git/ceph/ceph/build/bin}
BT=$BIN/ceph-bluestore-tool
WORK=${WORK:-/root/bh}
CONF=$WORK/ceph.conf
mkdir -p "$WORK"

# mkosd <dir> <block-size-bytes> [extra ceph-osd args...]
mkosd() {
  local d=$1 sz=$2; shift 2
  rm -rf "$d"; mkdir -p "$d"
  : > $CONF
  rm -f "$d.img"; truncate -s "$sz" "$d.img"
  $BIN/ceph-osd -c $CONF --no-mon-config -i 0 --mkfs \
    --osd-data "$d" --osd-uuid "$(uuidgen)" --fsid "$(uuidgen)" \
    --osd-objectstore bluestore --bluestore-block-path "$d.img" \
    --bluestore-fsck-on-mkfs=false --log-file "$d/mkfs.log" "$@" \
    >/dev/null 2>&1 || { echo "mkfs failed, see $d/mkfs.log"; tail -20 "$d/mkfs.log"; return 1; }
}
