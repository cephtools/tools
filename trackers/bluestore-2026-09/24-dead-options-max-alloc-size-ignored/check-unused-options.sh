#!/bin/bash
# Static check: BlueStore options declared in global.yaml.in with no consumer.
# Usage: SRC=/path/to/ceph repro.sh   (default: /root/git/ceph/ceph)
set -u
SRC=${SRC:-/root/git/ceph/ceph}
cd $SRC/src || exit 2
dead=0
for o in bluestore_max_alloc_size bluestore_qfsck_on_mount bluestore_bluefs_max_free \
         bluestore_cleaner_sleep_interval bluestore_cache_trim_max_skip_pinned \
         bluestore_bitmapallocator_blocks_per_zone bluestore_bitmapallocator_span_size \
         bluestore_debug_prefragment_max bluestore_debug_freelist bdev_nvme_unbind_from_kernel; do
  uses=$(grep -rw "$o" --include=*.cc --include=*.h . | grep -v "/options/\|/test/" \
         | grep -v "changed.count\|\"$o\"s,$")
  if [ "$o" = bluestore_max_alloc_size ]; then
    # read into a member that is never used for allocation
    grep -rn "[^_]max_alloc_size[^_]" os/bluestore/BlueStore.cc | grep -v "bluestore_max_alloc_size\|<< \" max_alloc_size" \
      | grep -q . && uses=USED || uses=""
  fi
  if [ -z "$uses" ]; then echo "  DEAD: $o"; dead=1; else echo "  used: $o"; fi
done
[ $dead -ne 0 ] && { echo "FAIL (options declared but silently ignored)"; exit 1; }
echo PASS
