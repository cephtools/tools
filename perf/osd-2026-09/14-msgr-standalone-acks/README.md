# Messenger: a standalone ACK frame for every OSD-to-OSD message

| | |
|---|---|
| Area | AsyncMessenger v2 (`ProtocolV2::handle_message`, `write_event`) |
| Change | small (switch 14 in `common/measurement-switches.patch`) |
| Expected gain | measured: not shown (OSD CPU per write −1.9%, within noise) |
| Risk | low to medium (more unacknowledged messages kept for replay) |
| Status | **not shown** by the measurement (2026-09-25) |

## Summary

OSD-to-OSD connections are lossless (`Messenger::Policy::lossless_peer`,
`ceph_osd.cc:613`). For every message received on such a connection,
`handle_message` does `ack_left++` and wakes the connection's writer
(`ProtocolV2.cc:1512-1516`, `:1571`). If no message is waiting to go out, the
writer builds and sends a standalone `AckFrame` (`:715-727`). An ACK only
rides for free on a real message when one is already queued
(`write_message`, `:534-535`, sends `ack_seq = in_seq`).

A replicated write sends two `MOSDRepOp`s and gets two `MOSDRepOpReply`s, and
the reply is only ready after the commit, so each client write causes about 4
standalone ACK frames across the cluster: a `sendmsg`, and on the peer an
epoll wakeup, a receive and the frame checks.

## Measured

Switch 14: wake the writer for an ACK only after 32 unacknowledged messages;
otherwise the ACK rides on the next outgoing message, which on a replica
connection comes within one round trip. (Measurement only: an idle connection
keeps up to 31 messages unacknowledged.)

3 BlueStore OSDs on brd ramdisks, 3 interleaved rounds
(`results/2026-09-25-ab3.txt`): OSD CPU per 4k write 659 [633..683] →
647 [635..654] µs (−1.9%), and no other change beyond noise. The
context-switch metric of the harness counts only `tp_osd_tp` threads, so it
does not show the messenger side.

So the standalone ACKs cost at most a few percent of OSD CPU here. TCP
`sendmsg` is 4.1% of OSD CPU on writes in the profile; it has no call chains
that would split it between ACK frames and real messages.
