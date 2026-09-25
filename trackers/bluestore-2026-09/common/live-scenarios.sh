#!/bin/bash
# Live-OSD reproducers: each scenario starts a fresh 1-OSD vstart cluster and
# triggers the bug only through real client I/O (librados python bindings,
# rados CLI) and real admin commands.  usage: bash live-scenarios.sh 02 03 ...
set -u
. "$(dirname "$0")/live-common.sh"
PY=python3

s02() {  # hybrid allocator: fragmented OSD (bitmap spillover) + online expand
  vstart_up "bluestore_block_size = 1181114368" "bluestore_hybrid_alloc_mem_cap = 8192" \
            "bluestore_min_alloc_size_hdd = 4096" "mon_osd_full_ratio = 0.99" \
            "mon_osd_backfillfull_ratio = 0.99" "mon_osd_nearfull_ratio = 0.99" \
            "osd_failsafe_full_ratio = 0.999" || return
  local BLK=$VSTART_DEST/dev/osd0/block
  echo "-- fragment: write 4000 x 64K, delete every other one"
  $PY - <<'EOF'
import rados
c=rados.Rados(conffile="", conf={"rados_osd_op_timeout":"20","rados_mon_op_timeout":"20"}); c.conf_read_file(); c.connect(); io=c.open_ioctx("p")
for i in range(4000): io.write_full("f%d"%i, b"x"*65536)
for i in range(0,4000,2): io.remove_object("f%d"%i)
EOF
  grep -m1 "constructing fallback allocator" "$OSDLOG" | sed -E 's/^\S+ \S+ +-?[0-9]+ //'
  echo "-- grow 1.1G -> 2G (no label position crossed), online expand"
  truncate -s 2G "$BLK"; $C tell osd.0 bluestore bluefs-bdev-expand 2>&1 | grep -E "Expanding|updated" | head -2
  echo "-- fill the device"
  $PY - <<'EOF'
import rados
c=rados.Rados(conffile="", conf={"rados_osd_op_timeout":"20","rados_mon_op_timeout":"20"}); c.conf_read_file(); c.connect(); io=c.open_ioctx("p")
try:
  for i in range(600): io.write_full("g%d"%i, b"y"*(4<<20))
except Exception as e: print("write stopped:", e)
EOF
  sleep 3
  osd_alive && echo "OSD still running" || { echo "OSD DIED:"; crash_sig; }
  vstart_down
  "$BUILD/bin/ceph-bluestore-tool" --path "$VSTART_DEST/dev/osd0" -c "$CEPH_CONF" fsck 2>&1 \
    | grep -E "fsck error|fsck success|fsck status" | sed -E 's/^\S+ \S+ +-?[0-9]+ //' | head -6
}

s03() {  # write_v2 deferred reuse race, HDD OSD with 16K min_alloc (pre-Pacific HDD default was 64K)
  vstart_up "bluestore_write_v2 = true" "bluestore_min_alloc_size_hdd = 16384" || return
  $PY -u - <<'EOF'
import rados
c=rados.Rados(conffile="", conf={"rados_osd_op_timeout":"20","rados_mon_op_timeout":"20"}); c.conf_read_file(); c.connect(); io=c.open_ioctx("p")
A=b"A"*16384; B=b"B"*4096; C=b"C"*4096; D=b"D"*4096
io.write_full("race", A);      print("1 write_full A 16K")
io.write("race", B, 8192);     print("2 write B at 8K (deferred overwrite)")
with rados.WriteOpCtx() as w:
    w.zero(4096, 12288); io.operate_write_op(w, "race")
print("3 zero 4K~12K")
io.write("race", C, 0);        print("4 write C at 0 (AU released + reused)")
io.write("race", D, 8192);     print("5 write D at 8K (into unused part)")
print("read before restart ok:", io.read("race", 12288, 0) == C + b"\0"*4096 + D)
io.close(); c.shutdown()
EOF
  sleep 5; osd_restart
  $PY -u - <<'EOF'
import rados
c=rados.Rados(conffile="", conf={"rados_osd_op_timeout":"20","rados_mon_op_timeout":"20"}); c.conf_read_file(); c.connect(); io=c.open_ioctx("p")
try:
  d=io.read("race", 12288, 0)
  print("read after restart ok:", d == b"C"*4096 + b"\0"*4096 + b"D"*4096, "bytes@0,4K,8K=%r %r %r" % (d[0:1], d[4096:4097], d[8192:8193]))
except Exception as e: print("read after restart FAILED:", e)
io.close(); c.shutdown()
EOF
  grep -m2 "_verify_csum bad" "$OSDLOG" | sed -E 's/^\S+ \S+ +-?[0-9]+ //' | cut -c1-200
  vstart_down
}

s04() {  # omap_set + omap_rm_range in ONE librados write op
  vstart_up || return
  $PY -u - <<'EOF'
import rados
c=rados.Rados(conffile="", conf={"rados_osd_op_timeout":"20","rados_mon_op_timeout":"20"}); c.conf_read_file(); c.connect(); io=c.open_ioctx("p")
io.write_full("o", b"")
with rados.WriteOpCtx() as w:
    io.set_omap(w, ("a","d"), (b"1",b"4")); io.operate_write_op(w, "o")
with rados.WriteOpCtx() as w:
    io.set_omap(w, ("b",), (b"2",))        # set b ...
    io.remove_omap_range2(w, "a", "c")     # ... and remove [a,c) in the same op
    io.operate_write_op(w, "o")
with rados.ReadOpCtx() as r:
    it, ret = io.get_omap_vals(r, "", "", 100)
    io.operate_read_op(r, "o")
    keys = sorted(k for k, v in it)
print("omap keys after op:", keys, "(expected ['d'])")
io.close(); c.shutdown()
EOF
  vstart_down
}

s12() {  # write_v2 + bluestore_max_blob_size_hdd=0 set at runtime
  vstart_up "bluestore_write_v2 = true" || return
  $C config set osd bluestore_max_blob_size_hdd 0; $C config set osd bluestore_max_blob_size_ssd 0
  head -c 65536 /dev/urandom > "$VSTART_DEST/in"
  timeout 30 "$BUILD/bin/rados" -p p put obj "$VSTART_DEST/in"; echo "rados put rc=$?"
  sleep 2; osd_alive && echo "OSD still running" || { echo "OSD DIED:"; crash_sig; }
  vstart_down
}

s13() {  # pool compression_algorithm=none with compression_mode=force
  vstart_up || return
  for pool in ctl none; do
    $C osd pool create $pool 8 >/dev/null 2>&1; $C osd pool set $pool size 1 --yes-i-really-mean-it >/dev/null 2>&1
    $C osd pool set $pool compression_mode force >/dev/null
  done
  $C osd pool set ctl compression_algorithm lz4 >/dev/null
  $C osd pool set none compression_algorithm none; echo "set rc=$?"
  $C config set osd bluestore_compression_algorithm lz4
  python3 -c 'import sys; sys.stdout.buffer.write(b"a"*(4<<20))' > "$VSTART_DEST/in"
  for pool in ctl none; do
    for i in 1 2 3 4; do "$BUILD/bin/rados" -p $pool put o$i "$VSTART_DEST/in"; done
  done
  sleep 6
  $C df detail -f json 2>/dev/null | python3 -c 'import json,sys
d=json.load(sys.stdin)
for p in d["pools"]:
  if p["name"] in ("ctl","none"):
    s=p["stats"]; print("pool %-4s stored=%d compress_under_bytes=%d compress_bytes_used=%d" % (p["name"], s.get("stored",0), s.get("compress_under_bytes",0), s.get("compress_bytes_used",0)))'
  vstart_down
}

s15() {  # small write near 4 GiB into an object with a sharded extent map
  vstart_up "osd_max_object_size = 4294967295" || return
  $PY - <<'EOF'
import rados
c=rados.Rados(conffile="", conf={"rados_osd_op_timeout":"20","rados_mon_op_timeout":"20"}); c.conf_read_file(); c.connect(); io=c.open_ioctx("p")
for i in range(600): io.write("big", b"x"*4096, (1<<20) + i*8192)   # many extents -> sharded
try:
  io.write("big", b"y"*0x800, 0xffffe000); print("write near 4GiB returned ok")
except Exception as e: print("write near 4GiB failed:", e)
EOF
  sleep 3; osd_alive && echo "OSD still running" || { echo "OSD DIED:"; crash_sig; }
  vstart_down
}

for s in "$@"; do echo "######## scenario $s"; "s$s"; done
