#!/bin/bash
# BlueStore::_clone ceph_assert(oldo->onode.flags == newo->onode.flags) on an
# OSD still in OMAP_PER_POOL mode (Octopus-created, never quick-fixed).
# The Octopus on-disk state is recreated offline with ceph-kvstore-tool, then a
# plain self-managed-snapshot write (snapshot COW -> ObjectStore clone) is issued.
# usage: BUILD=<ceph>/build VSTART_DEST=/root/bh/vs bash repro.sh
set -u
COMMON=${COMMON:-$(dirname "$0")/../common}
. "$COMMON/live-common.sh"
[ -n "${LOCAL_OVERRIDE:-}" ] && . "$LOCAL_OVERRIDE"
PY=python3
OSDDIR=$VSTART_DEST/dev/osd0
KV="$BIN/ceph-kvstore-tool bluestore-kv $OSDDIR"

vstart_up || exit 1
echo "-- create omap object (written in the current, per-pg format)"
$PY -u - <<'EOF'
import rados
c=rados.Rados(conffile="", conf={"rados_osd_op_timeout":"20"}); c.conf_read_file(); c.connect()
io=c.open_ioctx("p")
io.write_full("omapobj", b"D"*8192)
with rados.WriteOpCtx() as w:
    io.set_omap(w, tuple("k%02d" % i for i in range(8)), tuple(b"v%02d" % i for i in range(8)))
    io.operate_write_op(w, "omapobj")
print("pool id", c.pool_lookup("p"))
EOF

echo "-- stop osd.0, convert it offline to the Octopus layout (per_pool_omap=1, PERPOOL-only object)"
pkill -f "ceph-osd -i 0 -c $CEPH_CONF"; sleep 5
KV="$KV" TMPD="$VSTART_DEST" $PY -u - <<'EOF'
import os, subprocess, struct, urllib.parse
KV = os.environ["KV"].split(); T = os.environ["TMPD"]
def kv(*a):
    r = subprocess.run(KV + list(a), capture_output=True, text=True)
    if r.returncode != 0:
        print("kvstore-tool FAILED:", " ".join(a[:3]), "rc=%d" % r.returncode)
        print(r.stderr[-800:]); raise SystemExit(1)
    return r.stdout
def unesc(s): return urllib.parse.unquote_to_bytes(s)
def esc(b): return "".join("%%%02x" % x for x in b)
def varint(b, p):
    v = s = 0
    while True:
        x = b[p]; p += 1; v |= (x & 0x7f) << s; s += 7
        if not x & 0x80: return v, p
# 1) onode: clear FLAG_PERPG_OMAP (8), keep OMAP|PERPOOL
okeys = [l.split("\t", 1)[1] for l in kv("list", "O").splitlines()
         if "\t" in l and "omapobj" in l and unesc(l.split("\t", 1)[1]).endswith(b"o")]
assert len(okeys) == 1, okeys
ok = okeys[0]; f = T + "/onode.bin"
kv("get", "O", ok, "out", f); v = bytearray(open(f, "rb").read())
p = 6                                   # struct_v, compat, u32 len
nid, p = varint(v, p); _, p = varint(v, p)
(n,) = struct.unpack_from("<I", v, p); p += 4
for _ in range(n):
    for _ in range(2):
        (l,) = struct.unpack_from("<I", v, p); p += 4 + l
print("nid", nid, "flags before 0x%x" % v[p]); assert v[p] & 0x9 == 0x9
v[p] &= ~0x8 & 0xff; print("flags after  0x%x" % v[p])
open(f, "wb").write(v); kv("set", "O", ok, "in", f)
# 2) move omap keys p:<pool><hash><nid>... -> m:<pool><nid>...
moved = 0
for l in kv("list", "p").splitlines():
    if "\t" not in l: continue
    k = unesc(l.split("\t", 1)[1])
    if struct.unpack(">Q", k[12:20])[0] != nid: continue
    kv("get", "p", esc(k), "out", f)
    kv("set", "m", esc(k[:8] + k[12:]), "in", f); kv("rm", "p", esc(k)); moved += 1
print("moved", moved, "omap keys p -> m")
# 3) store-wide mode OMAP_PER_POOL
open(f, "wb").write(b"1"); kv("set", "S", "per_pool_omap", "in", f)
print("S/per_pool_omap =", repr(open(f).read()))
EOF
echo "-- fsck of the converted (Octopus-like) store: expect success + 'not per-pg' warning"
$BIN/ceph-bluestore-tool --path $OSDDIR -c $CEPH_CONF fsck 2>&1 | grep -E "not per-pg|fsck error|fsck success|fsck status" | sed -E 's/^\S+ \S+ +-?[0-9]+ //' | head -4
(cd "$BUILD" && bin/ceph-osd -i 0 -c "$CEPH_CONF"); sleep 10
grep -m1 "per_pool_omap = " $OSDLOG | sed -E 's/^\S+ \S+ +-?[0-9]+ //'
echo "-- omap still readable in per-pool format:"
timeout 30 $BIN/rados -c $CEPH_CONF -p p listomapkeys omapobj | tr '\n' ' '; echo

echo "-- self-managed snapshot + 4K write -> make_writeable clones omapobj"
timeout 60 $PY -u - <<'EOF'
import rados
c=rados.Rados(conffile="", conf={"rados_osd_op_timeout":"20"}); c.conf_read_file(); c.connect()
io=c.open_ioctx("p")
s = io.create_self_managed_snap(); io.set_self_managed_snap_write([s])
try:
    io.write("omapobj", b"X"*4096, 0); print("write ok")
except Exception as e:
    print("write failed:", e)
EOF
sleep 3
if osd_alive; then
  echo "PASS: OSD survived snapshot COW of a legacy (per-pool) omap object"
else
  echo "BUG: OSD crashed cloning a legacy omap object:"; crash_sig
fi
vstart_down
$BIN/ceph-bluestore-tool --path $VSTART_DEST/dev/osd0 -c $CEPH_CONF fsck 2>&1 \
  | grep -E "fsck error|fsck success|fsck status" | sed -E 's/^\S+ \S+ +-?[0-9]+ //' | head -4
