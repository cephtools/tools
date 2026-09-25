#!/bin/bash
# osdprofile.sh -- where does OSD CPU go on the generic small-I/O path?
# Starts the osdperf-leg.sh cluster (3 BlueStore OSDs on brd ramdisks), then
# records all ceph-osd processes with perf (DWARF call graphs) during 4k
# writes and 4k random reads (on a large object set most reads miss the
# BlueStore cache), and prints the top symbols.  Needs root.
#
# Usage:  osdprofile.sh <build-dir> <outdir> [patches]
set -u
BUILD=$(realpath "${1:?build dir}")
OUT=${2:?out dir}
PATCHES=${3:-none}
SECS=${SECS:-20}
mkdir -p "$OUT"; OUT=$(realpath "$OUT")
HERE=$(cd "$(dirname "$0")" && pwd)

SETUP_ONLY=1 "$HERE/osdperf-leg.sh" "$BUILD" "$OUT/setup" "$PATCHES" > "$OUT/setup.log" 2>&1 \
	|| { echo "cluster setup failed, see $OUT/setup.log" >&2; exit 1; }
cd "$BUILD"
export CEPH_DEV=1
PIDS=$(pgrep -x ceph-osd | paste -sd,)

prof() {  # prof <tag> <pool> <rados bench args...>
	local tag=$1 pool=$2; shift 2
	bin/rados -p "$pool" bench $((SECS + 6)) "$@" > "$OUT/$tag.bench.txt" 2>&1 &
	local rb=$!
	sleep 3
	perf record -F 499 -g --call-graph dwarf,16384 -p "$PIDS" -o "$OUT/$tag.data" \
		-- sleep "$SECS" > "$OUT/$tag.record.log" 2>&1
	wait "$rb"
	perf report -i "$OUT/$tag.data" --no-children --sort symbol --stdio \
		--percent-limit 0.5 -g none 2>/dev/null | grep -v '^$' | head -70 > "$OUT/$tag.self.txt"
	perf report -i "$OUT/$tag.data" --children --sort symbol --stdio \
		--percent-limit 2 -g none 2>/dev/null | grep -v '^$' | head -90 > "$OUT/$tag.children.txt"
	perf report -i "$OUT/$tag.data" --no-children --sort comm --stdio -g none \
		2>/dev/null | grep -v '^$' | head -30 > "$OUT/$tag.threads.txt"
	echo "== $tag: $(grep -E '^Average IOPS' "$OUT/$tag.bench.txt")"
}

prof write4k rp write -b 4096 -t 64 --no-cleanup
prof read4k  rp rand -t 64

../src/stop.sh >/dev/null 2>&1 || true
pkill -9 -x ceph-osd; pkill -9 -x ceph-mon; pkill -9 -x ceph-mgr
echo "reports: $OUT/{write4k,read4k}.{self,children,threads}.txt"
