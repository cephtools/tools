# Withdrawn records (not for filing)

## 18 - BlueFS::invalidate_cache() aborts on a block-aligned offset with an unaligned length
The defect is real (`BlueFS.cc:2979-2999` rounds the length only when the offset is
unaligned, and `KernelDevice::invalidate_cache()` asserts `len % block_size == 0`,
KernelDevice.cc:1645), and the gtest reproduces the abort on origin/main 8e6a13e7a9a.

Withdrawn because no production path reaches it: in the bundled RocksDB (9.11) the only
non-wrapper caller of `InvalidateCache` is `SstFileWriter` with `(0, 0)`, which Ceph
does not use, and length 0 makes the BlueFS loop a no-op (`block_cache_compressed` no
longer exists). Keep it as a possible low-priority cleanup together with:
- the loop never advances to the next extent (only an incomplete fadvise hint);
- in the unaligned-offset branch, the length is not grown by the removed delta;
- RocksDB's contract says length 0 means "to end of file", BlueFS treats it as nothing.
