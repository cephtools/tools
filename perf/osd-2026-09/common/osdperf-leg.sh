#!/bin/bash
# osdperf-leg.sh -- one measurement leg of the OSD performance study on a
# vstart cluster with 3 BlueStore OSDs on brd ramdisks (CPU-bound OSD path).
#
# Usage:  osdperf-leg.sh <build-dir> <outdir> <patches> [conf-line ...]
#   <patches>    value for CEPH_PERF_PATCHES ("none", "01", "02,03", ...)
#   conf-line    extra ceph.conf lines, e.g. "osd_pg_object_context_cache_count = 512"
#
# Workloads (SECS each, default 30):
#   rw4k   rados bench write -b 4096 -t 64 on replicated pool rp (size 3)
#   rr4k   rados bench rand  -t 64 on the objects of rw4k
#   ec4k   rados bench write -b 4096 -t 16 on EC pool ep (k=2 m=1, overwrites + optimizations)
#   qd1    rados bench write -b 4096 -t 1 on rq
#   orr    rados bench rand -t 64 on pool op, 16000 objects (500 per PG, obc cache)
#   mixw   rados bench write -b 4096 -t 32 on rq while rand -t 32 runs on op
# Pools rp and ep are deleted after their workloads (8 GiB ramdisks).
# Per workload: rados bench summary, OSD CPU (utime+stime of all ceph-osd
# processes) per op, tp_osd_tp voluntary context switches per op, bluestore
# transactions per op, perf-counter latencies.
set -eu

BUILD=$(realpath "${1:?build dir}")
OUT=${2:?out dir}
PATCHES=${3:?patches}
shift 3
SECS=${SECS:-30}
RF_DELAY_MS=${RF_DELAY_MS:-0}    # record 03 delayed roll-forward (0 = stock)
VERIFY=${VERIFY:-0}              # 1: read back and verify the EC objects
DEVS=${DEVS:-/dev/ram0,/dev/ram1,/dev/ram2}
mkdir -p "$OUT"; OUT=$(realpath "$OUT")
cd "$BUILD"
export CEPH_DEV=1 2>/dev/null

osds() { bin/ceph osd ls; }
osd_pids() { pgrep -x ceph-osd; }

stop_cluster() {
	../src/stop.sh >/dev/null 2>&1 || true
	pkill -9 -x ceph-osd 2>/dev/null || true
	pkill -9 -x ceph-mon 2>/dev/null || true
	pkill -9 -x ceph-mgr 2>/dev/null || true
	sleep 2
}

cpu_ticks() {  # utime+stime of all OSDs, in clock ticks
	local p s=0
	for p in $(osd_pids); do
		s=$((s + $(awk '{print $14 + $15}' "/proc/$p/stat")))
	done
	echo "$s"
}

ctxsw() {  # voluntary context switches of all tp_osd_tp threads
	local p t s=0
	for p in $(osd_pids); do
		for t in /proc/$p/task/*; do
			grep -q '^tp_osd_tp$' "$t/comm" 2>/dev/null || continue
			s=$((s + $(awk '/^voluntary_ctxt_switches/ {print $2}' "$t/status")))
		done
	done
	echo "$s"
}

snap() {
	local i
	for i in $(osds); do
		bin/ceph tell "osd.$i" perf dump > "$OUT/$1.osd$i.json"
	done
}

report() {  # report <tag> <ops> <ticks> <ctxsw> <elapsed-s>
	python3 - "$OUT" "$1" "$2" "$3" "$4" "$(getconf CLK_TCK)" "$5" "$IDLE_TPS" $(osds) <<'EOF'
import json, sys
out, tag, ops, ticks, cs, hz, el, idle = sys.argv[1:9]
ids = sys.argv[9:]
ops, ticks, cs, hz, el, idle = int(ops), int(ticks), int(cs), int(hz), float(el), float(idle)
def d(sec, k, i):
    a = json.load(open(f"{out}/{tag}.before.osd{i}.json"))[sec][k]
    b = json.load(open(f"{out}/{tag}.after.osd{i}.json"))[sec][k]
    if isinstance(a, dict):
        return b["avgcount"] - a["avgcount"], b["sum"] - a["sum"]
    return b - a, 0
txc = sum(d("bluestore", "txc_commit_lat", i)[0] for i in ids)
print(f"ops                      {ops}")
print(f"osd_cpu_us_per_op        {ticks / hz * 1e6 / max(ops, 1):.1f}  (raw)")
net = max(ticks - idle * el, 0)
print(f"osd_cpu_us_per_op_net    {net / hz * 1e6 / max(ops, 1):.1f}  (idle {idle / hz:.2f} cores subtracted over {el:.1f} s)")
print(f"ctxsw_per_op             {cs / max(ops, 1):.2f}")
print(f"bluestore_txc_per_op     {txc / max(ops, 1):.2f}")
hit = sum(d("osd", "object_ctx_cache_hit", i)[0] for i in ids)
tot = sum(d("osd", "object_ctx_cache_total", i)[0] for i in ids)
print(f"obc_hit_rate             {hit / tot:.3f}" if tot else "obc_hit_rate             -")
for sec, k in (("osd", "op_w_latency"), ("osd", "op_r_latency"),
               ("osd", "subop_w_latency"), ("bluestore", "txc_commit_lat")):
    n = s = 0
    for i in ids:
        a, b = d(sec, k, i); n += a; s += b
    print(f"{sec + '.' + k:24} {s / n * 1e6:.1f} us" if n else f"{sec + '.' + k:24} -")
EOF
}

run() {  # run <tag> <pool> <rados bench args...>
	local tag=$1 pool=$2; shift 2
	snap "$tag.before"
	local t0 c0 t1 c1 ops w0 w1
	t0=$(cpu_ticks); c0=$(ctxsw); w0=$(date +%s.%N)
	bin/rados -p "$pool" bench "$SECS" "$@" > "$OUT/$tag.bench.txt" 2>&1
	t1=$(cpu_ticks); c1=$(ctxsw); w1=$(date +%s.%N)
	snap "$tag.after"
	ops=$(awk '/^Total (writes|reads) made/ {print $NF}' "$OUT/$tag.bench.txt")
	{
		echo "== $tag: rados -p $pool bench $SECS $*"
		grep -E '^(Average IOPS|Average Latency|Max latency)' "$OUT/$tag.bench.txt"
		report "$tag" "${ops:-0}" $((t1 - t0)) $((c1 - c0)) "$(echo "$w1 - $w0" | bc)"
	} | tee "$OUT/$tag.summary"
}

used_bytes() {
	bin/ceph df -f json 2>/dev/null |
		python3 -c 'import json,sys; print(json.load(sys.stdin)["stats"]["total_used_raw_bytes"])'
}

drop_pool() {  # delete a pool, then wait until the OSDs have freed its space,
	           # so PG deletion does not run during the next workload
	bin/ceph osd pool rm "$1" "$1" --yes-i-really-really-mean-it >/dev/null
	# wait until used space is back near the level after setup (PG deletion
	# done), or has not changed for 60 s; at most 300 s
	local i cur prev=0 still=0
	for i in $(seq 1 60); do
		sleep 5
		cur=$(used_bytes)
		[ "$cur" -lt $((BASE_USED + (1536 << 20))) ] && break
		if [ "$prev" -gt 0 ] && [ $((prev - cur)) -lt $((16 << 20)) ] && \
		   [ $((cur - prev)) -lt $((16 << 20)) ]; then
			still=$((still + 5))
			[ "$still" -ge 60 ] && break
		else
			still=0
		fi
		prev=$cur
	done
	echo "after dropping $1: used $(( $(used_bytes) >> 20 )) MiB" | tee -a "$OUT/leg.txt"
	sleep 5
}

# ---- cluster ----
for d in ${DEVS//,/ }; do
	[ "$(blockdev --getsize64 "$d" 2>/dev/null || echo 0)" -ge $((4 << 30)) ] \
		|| { echo "$d missing or < 4 GiB (modprobe brd rd_nr=3 rd_size=8388608)" >&2; exit 1; }
done
stop_cluster
for d in ${DEVS//,/ }; do blkdiscard -f "$d" 2>/dev/null || wipefs -a "$d" >/dev/null; done

conf=(
	-o "osd_memory_target = 4294967296"
	-o "osd_pool_default_pg_autoscale_mode = off"
	-o "osd_debug_op_order = false"
	-o "debug_ms = 0/0"
	-o "debug_osd = 0/0"
	-o "debug_bluestore = 0/0"
	-o "debug_bluefs = 0/0"
	-o "debug_bdev = 0/0"
	-o "debug_rocksdb = 0/0"
	-o "debug_optracker = 0/0"
	-o "osd_mclock_skip_benchmark = true"
	-o "osd_pool_default_flag_ec_optimizations = true"
)
for c in "$@"; do conf+=(-o "$c"); done

echo "leg: patches=$PATCHES rf_delay_ms=$RF_DELAY_MS conf=[$*]" | tee "$OUT/leg.txt"
CEPH_PERF_EC_RF_DELAY_MS=$RF_DELAY_MS CEPH_PERF_PATCHES=$PATCHES MON=1 OSD=3 MDS=0 MGR=1 RGW=0 NFS=0 \
	../src/vstart.sh -n -l --nolockdep --without-dashboard -b --bluestore-devs "$DEVS" \
	"${conf[@]}" > "$OUT/vstart.log" 2>&1
for p in $(osd_pids); do
	tr '\0' '\n' < "/proc/$p/environ" | grep -q "^CEPH_PERF_PATCHES=$PATCHES$" \
		|| { echo "osd pid $p does not have CEPH_PERF_PATCHES=$PATCHES" >&2; exit 1; }
	tr '\0' '\n' < "/proc/$p/environ" | grep -q "^CEPH_PERF_EC_RF_DELAY_MS=$RF_DELAY_MS$" \
		|| { echo "osd pid $p does not have CEPH_PERF_EC_RF_DELAY_MS=$RF_DELAY_MS" >&2; exit 1; }
done

bin/ceph osd pool create rp 32 32 replicated >/dev/null
bin/ceph osd pool set rp size 3 >/dev/null
bin/ceph osd pool create op 32 32 replicated >/dev/null
bin/ceph osd pool set op size 3 >/dev/null
bin/ceph osd pool create rq 32 32 replicated >/dev/null
bin/ceph osd pool set rq size 3 >/dev/null
bin/ceph osd erasure-code-profile set ec21 k=2 m=1 crush-failure-domain=osd >/dev/null
bin/ceph osd pool create ep 32 32 erasure ec21 >/dev/null
bin/ceph osd pool set ep allow_ec_overwrites true >/dev/null
bin/ceph osd pool ls detail | grep -E "'ep'" | grep -q ec_optimizations \
	|| { echo "pool ep does not have ec_optimizations" >&2; exit 1; }
[ "$(bin/ceph osd ls | wc -l)" = 3 ] && [ "$(bin/ceph osd stat -f json | python3 -c 'import json,sys; print(json.load(sys.stdin)["num_up_osds"])')" = 3 ] \
	|| { echo "not 3 OSDs up" >&2; exit 1; }
clean=0
for i in $(seq 1 90); do
	bin/ceph pg stat 2>/dev/null | grep -qE '^([0-9]+) pgs: \1 active\+clean' && { clean=1; break; }
	sleep 2
done
bin/ceph pg stat | tee -a "$OUT/leg.txt"
[ "$clean" = 1 ] || { echo "PGs not active+clean" >&2; exit 1; }
{
	echo "osd_debug_op_order (effective): $(bin/ceph config show osd.0 osd_debug_op_order)"
	echo "osd_op_queue: $(bin/ceph config show osd.0 osd_op_queue)"
	echo "binary: patched build, switches '$PATCHES'"
} | tee -a "$OUT/leg.txt"
sleep 5
BASE_USED=$(used_bytes)
echo "used after setup: $((BASE_USED >> 20)) MiB" | tee -a "$OUT/leg.txt"
# idle OSD CPU rate (ticks per second), subtracted from each workload
i0=$(cpu_ticks); sleep 10; i1=$(cpu_ticks)
IDLE_TPS=$(echo "($i1 - $i0) / 10" | bc -l)
echo "idle osd cpu: $IDLE_TPS ticks/s" | tee -a "$OUT/leg.txt"
# SETUP_ONLY=1: leave the cluster running for another tool (osdprofile.sh)
[ "${SETUP_ONLY:-0}" = 1 ] && exit 0

# ---- workloads ----
# The ramdisks are 8 GiB: drop each big write pool after use.
run rw4k rp write -b 4096 -t 64 --no-cleanup
run rr4k rp rand -t 64
drop_pool rp
run ec4k ep write -b 4096 -t 16 --no-cleanup
if [ "$VERIFY" = 1 ]; then
	sleep 2
	bin/rados -p ep bench 20 seq -t 16 > "$OUT/ec4k-verify.txt" 2>&1 \
		|| { echo "EC read-back verify FAILED" | tee -a "$OUT/leg.txt"; exit 1; }
	echo "EC read-back verify: $(awk '/^Total reads made/ {print $NF}' "$OUT/ec4k-verify.txt") objects read and checked" | tee -a "$OUT/leg.txt"
fi
drop_pool ep
run qd1  rq write -b 4096 -t 1 --no-cleanup
# small object set for the obc cache: 16000 objects over 32 PGs = 500 per PG
bin/rados -p op bench 120 write -b 4096 -t 64 --max-objects 16000 --run-name small --no-cleanup > "$OUT/ow.bench.txt" 2>&1
run orr  op rand -t 64 --run-name small
# mixed: random reads on op while 4k writes run on rp (commit callbacks vs
# the owner thread's in-flight op, record 01); the summary is for the writes
bin/rados -p op bench "$((SECS + 4))" rand -t 32 --run-name small > "$OUT/mixr.bench.txt" 2>&1 &
RD=$!
sleep 2
run mixw rq write -b 4096 -t 32 --no-cleanup
wait "$RD" || true
grep -E '^(Average IOPS|Average Latency)' "$OUT/mixr.bench.txt" | sed 's/^/reads: /' | tee -a "$OUT/mixw.summary"

bin/ceph osd pool ls detail > "$OUT/pools.txt" 2>&1
stop_cluster
