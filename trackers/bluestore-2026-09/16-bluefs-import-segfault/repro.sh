#!/bin/bash
# ceph-bluestore-tool bluefs-import uses raw FileWriter::append() and never
# checks open_for_write(); with bluefs_wal_envelope_mode=true (default) any
# *.log destination is an ENVELOPE file whose head filler is never set up ->
# crash at fsync.  Also a missing dest dir uses an uninitialized handle.
set -u
. ${COMMON:-$(dirname $0)/../common/common.sh}
D=$WORK/bfimport
mkosd $D 4G || exit 1
head -c 100000 /dev/urandom > $WORK/bfimport.in
echo "== import to db/bughunt.sst (non-envelope, control)"
$BT bluefs-import --path $D --input-file $WORK/bfimport.in --dest-file db/bughunt.sst >/dev/null 2>&1; echo "exit=$?"
echo "== import to db.wal/999999.log (envelope mode)"
$BT bluefs-import --path $D --input-file $WORK/bfimport.in --dest-file db.wal/999999.log --log-file $D/imp.log >/dev/null 2>&1; echo "exit=$? (139/134 = crash)"
echo "== import to nosuchdir/x"
$BT bluefs-import --path $D --input-file $WORK/bfimport.in --dest-file nosuchdir/x --log-file $D/imp2.log >/dev/null 2>&1; echo "exit=$? (expect clean error)"
