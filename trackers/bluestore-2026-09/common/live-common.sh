# helpers for live-OSD reproducers (vstart, 1 OSD, pool "p" size 1)
BUILD=${BUILD:-/root/git/ceph/ceph/build}
export VSTART_DEST=${VSTART_DEST:-/root/bh/vs}
export CEPH_CONF=$VSTART_DEST/ceph.conf
export PYTHONPATH=$BUILD/lib/cython_modules/lib.3
export LD_LIBRARY_PATH=$BUILD/lib
C="$BUILD/bin/ceph"
OSDLOG=$VSTART_DEST/out/osd.0.log

# vstart_up "<extra -o option>" ...   (each arg is one "key = value" line)
vstart_up() {
  local opts=()
  for o in "$@"; do opts+=(-o "$o"); done
  (cd "$BUILD" && ../src/stop.sh >/dev/null 2>&1)
  rm -rf "$VSTART_DEST"; mkdir -p "$VSTART_DEST"
  (cd "$BUILD" && MON=1 OSD=1 MDS=0 MGR=1 RGW=0 OSD_POOL_DEFAULT_SIZE=1 \
     ../src/vstart.sh -n -x --without-dashboard "${opts[@]}" > "$VSTART_DEST/vstart.log" 2>&1) \
    || { echo "vstart failed"; tail -20 "$VSTART_DEST/vstart.log"; return 1; }
  $C osd pool create p 8 >/dev/null 2>&1
  $C osd pool set p size 1 --yes-i-really-mean-it >/dev/null 2>&1
  $C osd pool application enable p rados >/dev/null 2>&1
  return 0
}
vstart_down() { (cd "$BUILD" && ../src/stop.sh >/dev/null 2>&1); sleep 2; }
osd_alive() { pgrep -f "ceph-osd -i 0 -c $CEPH_CONF" >/dev/null; }
osd_restart() {
  pkill -f "ceph-osd -i 0 -c $CEPH_CONF"; sleep 3
  (cd "$BUILD" && bin/ceph-osd -i 0 -c "$CEPH_CONF") ; sleep 8
}
crash_sig() {   # print the first assert/signal line from the OSD log
  grep -m3 -E "FAILED ceph_assert|Caught signal" "$OSDLOG" 2>/dev/null | sed -E 's/^\S+ \S+ +-?[0-9]+ //' | cut -c1-200
}
