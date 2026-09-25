#!/bin/bash
# osdperf-ab.sh -- one A/B leg for the OSD performance candidates (records 01-12).
# Run once on the stock build, once on the patched build (or with a config
# change), same lab, same pool; then compare the two summary files.
#
# Usage:  osdperf-ab.sh <ceph-build-dir> <outdir> [pool]
#
# Per workload it records:
#   - rados bench summary (IOPS, avg/max latency)
#   - per-OSD perf-counter deltas: op_w_latency, op_w_process_latency,
#     subop_w_latency, op_r_latency, op_before_dequeue_op_lat,
#     bluestore txc_commit_lat, state_prepare_lat, txc_submit_lat, read_wait_aio_lat
#   - voluntary context switches of all tp_osd_tp threads, per op   (record 05)
#   - io_submit time in tp_osd_tp threads, if bpftrace is present   (record 07)
# The record-01 signal is op_w_latency minus txc_commit_lat on the primary side.
set -eu

BUILD=${1:?ceph build dir}
OUT=${2:?output dir}
POOL=${3:-p1}
SECS=${SECS:-30}
mkdir -p "$OUT"; OUT=$(realpath "$OUT")
cd "$BUILD"

osds() { bin/ceph osd ls; }
osd_pid() { pgrep -f "ceph-osd -i $1 " | head -1; }

ctxsw() {   # sum of voluntary_ctxt_switches over tp_osd_tp threads of all OSDs
	local i p t s=0
	for i in $(osds); do
		p=$(osd_pid "$i")
		for t in /proc/$p/task/*; do
			grep -q '^tp_osd_tp$' "$t/comm" 2>/dev/null || continue
			s=$((s + $(awk '/^voluntary_ctxt_switches/ {print $2}' "$t/status")))
		done
	done
	echo "$s"
}

snap() {    # snap <tag>: perf dump of every OSD
	local i
	for i in $(osds); do
		bin/ceph tell "osd.$i" perf dump > "$OUT/$1.osd$i.json"
	done
}

diffs() {   # diffs <before> <after> <ops>
	python3 - "$OUT" "$1" "$2" "$3" $(osds) <<'EOF'
import json, sys
out, a, b, ops, ids = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5:]
keys = [("osd", k) for k in ("op_w_latency", "op_w_process_latency", "subop_w_latency",
                             "op_r_latency", "op_before_dequeue_op_lat")] + \
       [("bluestore", k) for k in ("txc_commit_lat", "state_prepare_lat",
                                   "txc_submit_lat", "read_wait_aio_lat")]
print(f"{'counter':34}" + "".join(f"{'osd.'+i:>12}" for i in ids) + "   (us, avg over the run)")
for sec, k in keys:
    row = []
    for i in ids:
        x = json.load(open(f"{out}/{a}.osd{i}.json"))[sec][k]
        y = json.load(open(f"{out}/{b}.osd{i}.json"))[sec][k]
        n = y["avgcount"] - x["avgcount"]
        row.append(f"{(y['sum'] - x['sum']) / n * 1e6:12.1f}" if n else f"{'-':>12}")
    print(f"{sec + '.' + k:34}" + "".join(row))
EOF
}

bt_start() {   # io_submit latency in tp_osd_tp, per OSD pid
	command -v bpftrace >/dev/null || return 0
	[ "$(id -u)" = 0 ] || return 0      # bpftrace needs root
	bpftrace -e '
tracepoint:syscalls:sys_enter_io_submit /comm == "tp_osd_tp"/ { @s[tid] = nsecs; }
tracepoint:syscalls:sys_exit_io_submit /@s[tid]/ {
	@io_submit_us[pid] = hist((nsecs - @s[tid]) / 1000); delete(@s[tid]); }' \
		> "$OUT/$1.io_submit.txt" 2>&1 &
	BT=$!
	sleep 3
}
bt_stop() { [ -n "${BT:-}" ] && kill -INT "$BT" && wait "$BT" || true; BT=; }

run() {        # run <tag> <rados bench args...>
	local tag=$1; shift
	echo "== $tag: rados bench $*" | tee "$OUT/$tag.summary"
	snap "$tag.before"; local c0; c0=$(ctxsw)
	bt_start "$tag"
	bin/rados -p "$POOL" bench "$SECS" "$@" > "$OUT/$tag.bench.txt"
	bt_stop
	local c1; c1=$(ctxsw); snap "$tag.after"
	local ops; ops=$(awk '/^Total (writes|reads) made/ {print $NF}' "$OUT/$tag.bench.txt")
	grep -E '^(Bandwidth|Average IOPS|Average Latency|Max latency|Stddev Latency)' \
		"$OUT/$tag.bench.txt" | tee -a "$OUT/$tag.summary"
	echo "tp_osd_tp voluntary ctx switches per op: $(( (c1 - c0) / (ops ? ops : 1) ))" \
		| tee -a "$OUT/$tag.summary"
	diffs "$tag.before" "$tag.after" "$ops" | tee -a "$OUT/$tag.summary"
}

# W1: QD1 4k writes -- the queue drains after every op: wakeup herd (record 05),
#     commit-owner delay (record 01) in its cleanest form.
run w1-qd1-write write -b 4096 -t 1 --no-cleanup
# W2: QD32 4k writes -- CPU per op under the PG lock (record 12), record 01 under load.
run w2-qd32-write write -b 4096 -t 32 --no-cleanup
# W3: cold-cache random reads while W2-style writes run on the same PGs.
#     The context switches per op are divided by the writes only (the reads
#     add switches too), and the read bench starts ~3 s before the writes:
#     compare W3 only against W3 of the other leg.
#     Reads hold the PG lock across the device (record 08); the commits of the
#     shard wait for them when the owner thread reads (record 01).
for i in $(osds); do bin/ceph tell "osd.$i" cache drop >/dev/null; done
bin/rados -p "$POOL" bench "$SECS" rand -t 16 > "$OUT/w3-reads.bench.txt" &
RD=$!
run w3-mixed-write write -b 4096 -t 16 --no-cleanup
wait "$RD"
grep -E '^(Average IOPS|Average Latency|Max latency)' "$OUT/w3-reads.bench.txt" \
	| sed 's/^/reads: /' | tee -a "$OUT/w3-mixed-write.summary"
