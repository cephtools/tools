#!/bin/bash
# check02.sh -- is switch 02 active?  Counts PG::publish_stats_to_osd and
# PeeringState::prepare_stats_for_publish (the full path) calls during 10 s of
# 4k random reads, with switch 02 off and on.  Needs root (bpftrace) and the
# brd ramdisks of osdperf-leg.sh.
#
# Usage:  check02.sh <ceph-build-dir>
set -u
cd "${1:?ceph build dir}"
export CEPH_DEV=1
for P in none 02; do
	../src/stop.sh >/dev/null 2>&1; pkill -9 -x ceph-osd; pkill -9 -x ceph-mon; pkill -9 -x ceph-mgr; sleep 2
	for d in /dev/ram0 /dev/ram1 /dev/ram2; do blkdiscard -f $d; done
	CEPH_PERF_PATCHES=$P MON=1 OSD=3 MDS=0 MGR=1 RGW=0 NFS=0 ../src/vstart.sh -n -l --nolockdep --without-dashboard -b \
		--bluestore-devs /dev/ram0,/dev/ram1,/dev/ram2 -o "osd_mclock_skip_benchmark = true" -o "debug_ms = 0/0" \
		-o "osd_debug_op_order = false" >/tmp/check02-vstart.log 2>&1
	bin/ceph osd pool create rp 32 32 >/dev/null 2>&1; bin/ceph osd pool set rp size 3 >/dev/null 2>&1; sleep 15
	bin/rados -p rp bench 10 write -b 4096 -t 64 --no-cleanup >/dev/null 2>&1
	OSD=$(realpath bin/ceph-osd)
	timeout 25 bpftrace -e "uprobe:$OSD:_ZN2PG20publish_stats_to_osdEv { @pub = count(); }
		uprobe:$OSD:_ZN12PeeringState25prepare_stats_for_publishERKSt8optionalI9pg_stat_tERK24object_stat_collection_t { @full = count(); }" \
		> /tmp/check02-bt.txt 2>&1 &
	BT=$!; sleep 12
	bin/rados -p rp bench 10 rand -t 64 > /tmp/check02-rand.txt 2>&1
	kill -INT $BT; wait $BT
	echo "== patches=$P  reads: $(awk '/^Total reads made/ {print $NF}' /tmp/check02-rand.txt)"
	grep -E '@pub|@full|ERROR|No probes' /tmp/check02-bt.txt
done
../src/stop.sh >/dev/null 2>&1
