#!/bin/bash
# rm_range_keys on a sharded/CF prefix ignores the range end when
# osd_rocksdb_iterator_bounds_enabled=false -> an omap_rm_range / omap_clear /
# object delete on ONE object wipes omap keys of OTHER objects (and pgmeta).
# usage: BUILD=<ceph>/build VSTART_DEST=/tmp/bhvs bash repro.sh
set -u
COMMON=${COMMON:-$(dirname "$0")/../common}
. "$COMMON/live-common.sh"
PY=python3

vstart_up "osd_rocksdb_iterator_bounds_enabled = false" || exit 1
$C config get osd.0 osd_rocksdb_iterator_bounds_enabled
$PY -u - <<'PYEOF'
import rados
c=rados.Rados(conffile="", conf={"rados_osd_op_timeout":"20","rados_mon_op_timeout":"20"}); c.conf_read_file(); c.connect()
io=c.open_ioctx("p")
def setkv(o, keys):
    io.write_full(o, b"")
    with rados.WriteOpCtx() as w:
        io.set_omap(w, tuple(keys), tuple(b"v" for _ in keys)); io.operate_write_op(w, o)
def keys(o):
    with rados.ReadOpCtx() as r:
        it, ret = io.get_omap_vals(r, "", "", 10000); io.operate_read_op(r, o)
        return sorted(k for k, v in it)
# 'victim' objects are created AFTER 'a' -> larger nid -> sort after it in the CF
setkv("a", ["k%02d" % i for i in range(10)])
for i in range(20): setkv("victim%d" % i, ["x", "y", "z"])
before = sum(len(keys("victim%d" % i)) for i in range(20))
print("a keys before:", keys("a"))
print("victim keys before (total):", before)
with rados.WriteOpCtx() as w:           # remove [k02,k04) of object 'a' only
    io.remove_omap_range2(w, "k02", "k04"); io.operate_write_op(w, "a")
print("a keys after rm_range [k02,k04):", keys("a"), "(expected k00 k01 k04..k09)")
after = sum(len(keys("victim%d" % i)) for i in range(20))
print("victim keys after (total):", after, "(expected %d)" % before)
PYEOF
echo "-- restart OSD (pgmeta/pg info may have been wiped as well)"
osd_restart; sleep 5
osd_alive && echo "OSD alive after restart" || { echo "OSD DIED after restart:"; crash_sig; }
vstart_down
if [ -x "$BUILD/bin/ceph-bluestore-tool" ]; then
  "$BUILD/bin/ceph-bluestore-tool" --path "$VSTART_DEST/dev/osd0" -c "$CEPH_CONF" fsck 2>&1 \
    | grep -E "fsck error|fsck success|fsck status" | head -6
fi
