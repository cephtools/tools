#!/bin/sh
# fio-rbd-lat.sh - turn-key tracer for fio IOs with long latency, supporting
# distro-shipped fio/fio-rbd on Fedora and Ubuntu/Debian (and self-built fio).
#
# Per IO two correlated events are traced:
#   rbd_cmpl : fio_rbd_queue() -> _fio_rbd_finish_aiocb()   librbd/cluster time
#   clat     : fio's clat from add_clat_sample()             includes reap delay
# A slow clat with a fast rbd_cmpl means time was lost in fio's event loop,
# not in ceph.  If no rbd engine is found, clat-only tracing still works for
# any ioengine.
#
# Everything is resolved at runtime, in this order:
#   symbols       : nm -> nm -D (-rdynamic exports) -> separate debug file
#   debug files   : /usr/lib/debug via build-id -> debuginfod download
#                   -> distro debug package install (disable: NO_INSTALL=1)
#   io_u offsets  : gdb DWARF query (override: IOU_OFF/XFER_OFF/DDIR_OFF)
#   ABI variant   : gdb 'whatis add_clat_sample' (io_u arg vs offset arg)
#
# Usage: ./fio-rbd-lat.sh [threshold_us] [fio_path] [rbd_engine_path]
#        defaults: 20000 us, $(command -v fio), auto-detected engine
#
# Each line also shows which RBD object the IO starts in (OBJECT column,
# 16-digit hex) and the offset within it.  Full object name =
# <block_name_prefix>.<OBJECT>, both from 'rbd info <pool>/<image>'.
# Default object size is 4 MiB (order 22); for images with a different
# order run with RBD_OBJ_SIZE=$((1 << order)).  Assumes default striping
# (stripe_count=1); an IO crossing an object boundary reports the first
# object it touches.

set -u

THRESH=${1:-20000}
FIO=${2:-$(command -v fio || echo /usr/bin/fio)}
SO=${3:-}
OBJSZ=${RBD_OBJ_SIZE:-4194304}

[ -e "$FIO" ] || { echo "error: fio binary not found at $FIO" >&2; exit 1; }

# ---------------------------------------------------------------- distro bits
ID=unknown; ID_LIKE=""
[ -r /etc/os-release ] && . /etc/os-release
case "$ID $ID_LIKE" in
*fedora*|*rhel*|*centos*) PKGSYS=rpm ;;
*ubuntu*|*debian*)        PKGSYS=deb ;;
*)                        PKGSYS=none ;;
esac

if [ -z "${DEBUGINFOD_URLS:-}" ]; then
	case "$PKGSYS" in
	rpm) DEBUGINFOD_URLS="https://debuginfod.fedoraproject.org/" ;;
	deb) DEBUGINFOD_URLS="https://debuginfod.ubuntu.com https://debuginfod.debian.net" ;;
	*)   DEBUGINFOD_URLS="https://debuginfod.elfutils.org/" ;;
	esac
fi
export DEBUGINFOD_URLS
# don't let a slow/unreachable debuginfod server hang resolution; the distro
# package fallback kicks in instead
export DEBUGINFOD_TIMEOUT=${DEBUGINFOD_TIMEOUT:-15}

for t in bpftrace nm readelf gdb awk; do
	command -v "$t" >/dev/null 2>&1 && continue
	echo "error: required tool '$t' not installed" >&2
	case "$PKGSYS" in
	rpm) echo "       try: dnf install -y bpftrace binutils gdb" >&2 ;;
	deb) echo "       try: apt-get install -y bpftrace binutils gdb" >&2 ;;
	esac
	exit 1
done

# ------------------------------------------------- debug file for a binary
# prints path of separate debug file for $1, or nothing
debug_file() {
	_bid=$(readelf -n "$1" 2>/dev/null | awk '/Build ID/ {print $3; exit}')
	[ -n "$_bid" ] || return 0
	_d="/usr/lib/debug/.build-id/$(echo "$_bid" | cut -c1-2)/$(echo "$_bid" | cut -c3-).debug"
	if [ ! -e "$_d" ]; then
		for _g in /usr/lib/debug"$1"-*.debug /usr/lib/debug"$1".debug; do
			[ -e "$_g" ] && { _d=$_g; break; }
		done
	fi
	if [ ! -e "$_d" ] && command -v debuginfod-find >/dev/null 2>&1; then
		_d=$(debuginfod-find debuginfo "$1" 2>/dev/null)
	fi
	[ -e "${_d:-/nonexistent}" ] && echo "$_d"
}

# try to install distro debug packages for binary $1 (once per file)
install_debug() {
	[ -n "${NO_INSTALL:-}" ] && return 1
	case "$PKGSYS" in
	rpm)
		_p=$(rpm -qf --qf '%{NAME}' "$1" 2>/dev/null) || return 1
		echo "installing debuginfo for $_p ..." >&2
		dnf -q debuginfo-install -y "$_p" >&2
		;;
	deb)
		_p=$(dpkg -S "$1" 2>/dev/null | cut -d: -f1) || return 1
		echo "installing ${_p}-dbgsym (needs ddebs.ubuntu.com repo) ..." >&2
		apt-get -qq install -y "${_p}-dbgsym" >&2
		;;
	*) return 1 ;;
	esac
}

# resolve <file> <symbol> -> address (empty if not found)
resolve() {
	_a=$(nm "$1" 2>/dev/null | awk -v s="$2" '$3 == s && $2 ~ /^[TtWw]$/ {print $1; exit}')
	[ -n "$_a" ] || _a=$(nm -D "$1" 2>/dev/null | awk -v s="$2" '$3 == s && $2 ~ /^[TtWw]$/ {print $1; exit}')
	if [ -z "$_a" ]; then
		_dbg=$(debug_file "$1")
		[ -n "$_dbg" ] && _a=$(nm "$_dbg" 2>/dev/null | awk -v s="$2" '$3 == s && $2 ~ /^[TtWw]$/ {print $1; exit}')
	fi
	echo "$_a"
}

# one gdb pass for everything DWARF: three io_u offsets + clat signature
gdb_dwarf() {
	gdb --batch -iex 'set debuginfod enabled on' \
	    -ex 'print/d (int)&((struct io_u *)0)->offset' \
	    -ex 'print/d (int)&((struct io_u *)0)->xfer_buflen' \
	    -ex 'print/d (int)&((struct io_u *)0)->ddir' \
	    -ex 'whatis add_clat_sample' "$1" 2>/dev/null
}

# ------------------------------------------------------------ find the pieces
CADDR=$(resolve "$FIO" add_clat_sample)
if [ -z "$CADDR" ]; then
	install_debug "$FIO" && CADDR=$(resolve "$FIO" add_clat_sample)
fi
[ -n "$CADDR" ] || { echo "error: cannot resolve add_clat_sample in $FIO" >&2; exit 1; }

# rbd engine: explicit arg, known external .so locations, or built into fio
if [ -z "$SO" ]; then
	for p in /usr/lib64/fio/fio-rbd.so \
		 /usr/lib/x86_64-linux-gnu/fio/fio-rbd.so \
		 /usr/lib/fio/fio-rbd.so \
		 /usr/local/lib/fio/fio-rbd.so; do
		[ -e "$p" ] && { SO=$p; break; }
	done
	[ -n "$SO" ] || SO=$FIO	# maybe built-in
fi

QADDR=$(resolve "$SO" fio_rbd_queue)
KADDR=$(resolve "$SO" _fio_rbd_finish_aiocb)
if [ -z "$QADDR" ] || [ -z "$KADDR" ]; then
	install_debug "$SO" && {
		QADDR=$(resolve "$SO" fio_rbd_queue)
		KADDR=$(resolve "$SO" _fio_rbd_finish_aiocb)
	}
fi
RBD=1
if [ -z "$QADDR" ] || [ -z "$KADDR" ]; then
	echo "warning: rbd engine symbols not found ($SO); tracing clat only" >&2
	echo "         (Fedora: dnf install fio-engine-rbd; Ubuntu: rbd may be built-in, needs fio-dbgsym)" >&2
	RBD=0
fi

# --------------------------------------------- struct io_u offsets + ABI mode
DWARF=$(gdb_dwarf "$FIO")
IOU_OFF=${IOU_OFF:-$(echo "$DWARF" | awk '/^\$1 = /{print $3}')}
XFER_OFF=${XFER_OFF:-$(echo "$DWARF" | awk '/^\$2 = /{print $3}')}
DDIR_OFF=${DDIR_OFF:-$(echo "$DWARF" | awk '/^\$3 = /{print $3}')}
if [ -z "$IOU_OFF" ] || [ -z "$XFER_OFF" ] || [ -z "$DDIR_OFF" ]; then
	if install_debug "$FIO"; then
		DWARF=$(gdb_dwarf "$FIO")
		IOU_OFF=${IOU_OFF:-$(echo "$DWARF" | awk '/^\$1 = /{print $3}')}
		XFER_OFF=${XFER_OFF:-$(echo "$DWARF" | awk '/^\$2 = /{print $3}')}
		DDIR_OFF=${DDIR_OFF:-$(echo "$DWARF" | awk '/^\$3 = /{print $3}')}
	fi
fi
if [ -z "$IOU_OFF" ] || [ -z "$XFER_OFF" ] || [ -z "$DDIR_OFF" ]; then
	echo "error: cannot resolve struct io_u offsets from debug info of $FIO" >&2
	echo "       install fio debug symbols, or set IOU_OFF/XFER_OFF/DDIR_OFF manually" >&2
	exit 1
fi

# add_clat_sample's 5th arg: "struct io_u *" (fio >= 3.39) or raw offset (older)
if echo "$DWARF" | grep "^type = " | grep -q "struct io_u"; then
	CLAT_OFF_EXPR="*(uint64 *)(arg4 + $IOU_OFF)"
	CLAT_IOU_EXPR="arg4"
else
	CLAT_OFF_EXPR="arg4"
	CLAT_IOU_EXPR="(uint64)0"
fi

# ------------------------------------------------------------ build + run bt
TMP=$(mktemp /tmp/fio-rbd-lat.XXXXXX.bt) || exit 1
trap 'rm -f "$TMP"' EXIT INT TERM

cat > "$TMP" <<'EOF'
BEGIN
{
	@dname[0] = "read";
	@dname[1] = "write";
	@dname[2] = "trim";
	@dname[3] = "sync";

	printf("Tracing fio IOs with lat >= __THRESH__ us (rbd object size __OBJSZ__)... Ctrl-C to end.\n");
	printf("%-8s %-16s %-7s %-8s %-5s %14s %8s %9s %16s %9s %s\n",
	       "TIME", "COMM", "TID", "EVENT", "DDIR", "OFFSET", "LEN",
	       "LAT(us)", "OBJECT", "OBJ_OFF", "IO_U");
}

/* add_clat_sample(td, ddir, nsec, bs, ...): fio's clat accounting */
uprobe:__FIO__:0x__CADDR__
{
	$nsec = arg2;
	@clat_us = hist($nsec / 1000);

	if ($nsec >= (uint64)__THRESH__ * 1000) {
		$ddir = (int64)arg1;
		if ($ddir > 3) {
			$ddir = 3;
		}
		$off = __CLAT_OFF_EXPR__;
		time("%H:%M:%S ");
		printf("%-16s %-7d %-8s %-5s %14llu %8llu %9llu %016llx %9llu 0x%llx\n",
		       comm, tid, "clat", @dname[$ddir],
		       $off, arg3, $nsec / 1000,
		       $off / (uint64)__OBJSZ__, $off % (uint64)__OBJSZ__,
		       __CLAT_IOU_EXPR__);
	}
}
EOF

if [ "$RBD" = 1 ]; then
cat >> "$TMP" <<'EOF'

/* fio_rbd_queue(td, io_u): librbd submit; arg1 = io_u */
uprobe:__SO__:0x__QADDR__
{
	@qts[arg1] = nsecs;
}

/* _fio_rbd_finish_aiocb(comp, fri): librbd completion callback;
 * fri->io_u is the first member of struct fio_rbd_iou */
uprobe:__SO__:0x__KADDR__
{
	$iou = *(uint64 *)arg1;
	$qt = @qts[$iou];

	if ($qt > 0) {
		$lat = nsecs - $qt;
		delete(@qts[$iou]);
		@rbd_lat_us = hist($lat / 1000);

		if ($lat >= (uint64)__THRESH__ * 1000) {
			$ddir = (int64)*(uint32 *)($iou + __DDIR_OFF__);
			if ($ddir > 3) {
				$ddir = 3;
			}
			$off = *(uint64 *)($iou + __IOU_OFF__);
			time("%H:%M:%S ");
			printf("%-16s %-7d %-8s %-5s %14llu %8llu %9llu %016llx %9llu 0x%llx\n",
			       comm, tid, "rbd_cmpl", @dname[$ddir],
			       $off, *(uint64 *)($iou + __XFER_OFF__),
			       $lat / 1000,
			       $off / (uint64)__OBJSZ__, $off % (uint64)__OBJSZ__,
			       $iou);
		}
	}
}

END
{
	clear(@dname);
	clear(@qts);
}
EOF
else
cat >> "$TMP" <<'EOF'

END
{
	clear(@dname);
}
EOF
fi

sed -i "s|__FIO__|$FIO|g; s|__SO__|$SO|g; s|__CADDR__|$CADDR|g; \
	s|__QADDR__|${QADDR:-0}|g; s|__KADDR__|${KADDR:-0}|g; s|__THRESH__|$THRESH|g; \
	s|__IOU_OFF__|$IOU_OFF|g; s|__XFER_OFF__|$XFER_OFF|g; s|__DDIR_OFF__|$DDIR_OFF|g; \
	s|__CLAT_OFF_EXPR__|$CLAT_OFF_EXPR|g; s|__CLAT_IOU_EXPR__|$CLAT_IOU_EXPR|g; \
	s|__OBJSZ__|$OBJSZ|g" "$TMP"

echo "fio: $FIO (clat@0x$CADDR, arg4 mode: $CLAT_OFF_EXPR)" >&2
[ "$RBD" = 1 ] && echo "rbd engine: $SO (queue@0x$QADDR cmpl@0x$KADDR)" >&2
echo "io_u offsets: offset=$IOU_OFF xfer_buflen=$XFER_OFF ddir=$DDIR_OFF" >&2

# RESOLVE_ONLY=1: preflight - show what would be traced, don't attach
if [ -n "${RESOLVE_ONLY:-}" ]; then
	echo "--- generated bpftrace program ---" >&2
	cat "$TMP"
	exit 0
fi

exec bpftrace "$TMP"
