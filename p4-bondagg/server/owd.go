package main

import "time"

// nowMS is the truncated monotonic-ish millisecond stamp the wire header
// carries. Identical to p4-bondagg/daemon/paths.go:13 so both ends truncate the
// same way and int32 differences stay valid across the 32-bit wrap.
func nowMS() uint32 { return uint32(time.Now().UnixMilli() & 0xFFFFFFFF) }

// U159 DELETED the OWD type that used to live here. Its ONLY consumer was the
// reorder ring's adaptive hold (rx.go: ring.SetHold(owd.Hold(...))), and with
// the ring gone there is nothing on this box that a cross-link OWD spread
// answers a question for: the server writes every payload to WireGuard at
// arrival. nowMS stays because the wire header and the echo still carry it.
