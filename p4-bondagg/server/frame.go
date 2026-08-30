package main

import (
	"encoding/binary"
	"errors"
)

// 16-byte agg header, network order -- a VERBATIM MIRROR of the client's
// p4-bondagg/daemon/frame.go. The server is a separate Go module, so the layout
// is duplicated rather than imported: any change to the client header MUST be
// mirrored here or the two peers stop parsing each other. Nothing about the
// layout is re-designed; Pack/Unpack are the client's functions byte for byte.
//
// [0] magic 0xB0  [1] ver(4b)|flags(4b)  [2] pathID  [3] rsvd (=K on FlagFEC)
// [4:8] seq32     [8:12] txstamp ms (sender mono, truncated)  [12:16] fseq32
//
// How the pull server uses each field.
// rsvd (byte [3]): carries the per-path FEC group size K on a FlagFEC frame
// (daemon/fec.go, daemon/main.go:262,391 write it; :169,524 read it back as
// the client's own K). The pull server never sends or accepts FlagFEC (the
// pull datapath dropped FEC, ADR-002) and never reads this byte, so on the
// wire this server actually sees it is always 0 -- but the byte is USED
// elsewhere on the SAME wire format, not unused. Do not re-derive "unused"
// from this file alone; that mistake already produced one false design
// premise (U34 round 1).
// pathID: the LINK the frame was sent on. This is the ONLY place N enters the
// server -- a link exists the moment a frame carrying its pathID arrives. N is
// never configured and no index is privileged.
// seq32: the GLOBAL resequencer seq. The server reorders on this and on nothing
// else; it never looks inside the payload.
// txstamp: sender monotonic ms, truncated. Used for the relative-OWD /
// reorder-hold geometry (the clock offset cancels in the cross-link spread)
// and, on a FlagPing, echoed back VERBATIM so the client can lag-align the
// received-count echo in its OWN clock.
// fseq32: per-path sub-sequence. Parsed and discarded -- the pull datapath
// dropped FEC (ADR-002 / p5-execution-handover section 2).
const (
	Magic  = 0xB0
	Ver    = 2
	HdrLen = 16
)

const (
	FlagData = 0x0
	FlagPing = 0x1
	FlagPong = 0x2
	FlagFEC  = 0x3
	// FlagEcho carries the server's per-link received-count echo (echo.go).
	//
	// It is a NEW flag rather than a reuse of FlagPong, and that is the whole
	// point. FlagPong already means something in the other direction: the
	// CLIENT answers a server ping with a 6-byte R3 payload
	// [lp, qb, od, jt, dHi, dLo] (daemon/main.go:153). Replying to a client
	// ping with FlagPong and an 6+18N echo payload at an unchanged Ver=2
	// produces a byte-identical 16-byte header, so the shipped client's
	// `case FlagPong: if len(pay) >= pongLen` (daemon/main.go:156-162,
	// pongLen=6) ACCEPTS a 1482-byte echo and reinterprets it:
	//   pay[1] -- the echo's rsvd=0 -- becomes sched.OnQ(p, 0), i.e. a
	//     permanently clean uplink queue, so AIMD ramps to the ceiling and
	//     never backs off;
	//   pay[4:6] -- the low 16 bits of srvMS -- become delivered-bytes;
	//   pay[0]   -- nrec -- becomes lossPeerB.
	// No error, no log, garbage congestion input, invisible until hardware.
	// The same misparse exists at the second pong site, daemon/main.go:508-512.
	//
	// The client's RX switch (daemon/main.go:147) has cases for Ping, Pong,
	// FEC and Data and NO default, so a frame under an unknown flag is simply
	// dropped. A client that has not yet learned FlagEcho therefore loses the
	// echo -- which is the correct degradation -- instead of being fed noise.
	FlagEcho = 0x4
)

// MaxFrame bounds the RX buffer and matches the client's bound, which sizes for
// the largest frame a Ver-2 header can carry (a parity frame's 6-byte
// seqXOR+xlen prefix ahead of a full payload). The pull server never emits or
// accepts parity, but the buffer must still be able to READ one whole so a
// stale FEC-speaking peer is rejected cleanly instead of silently truncated.
const (
	MaxPayload = 1500
	MaxFrame   = HdrLen + 6 + MaxPayload
)

var ErrBadFrame = errors.New("bad frame")

func Pack(dst []byte, flags, pathID byte, seq, tsms, fseq uint32, payload []byte) int {
	dst[0] = Magic
	dst[1] = (Ver << 4) | (flags & 0x0F)
	dst[2] = pathID
	dst[3] = 0
	binary.BigEndian.PutUint32(dst[4:8], seq)
	binary.BigEndian.PutUint32(dst[8:12], tsms)
	binary.BigEndian.PutUint32(dst[12:16], fseq)
	copy(dst[HdrLen:], payload)
	return HdrLen + len(payload)
}

func Unpack(b []byte) (flags, pathID byte, seq, tsms, fseq uint32, payload []byte, err error) {
	if len(b) < HdrLen || b[0] != Magic || (b[1]>>4) != Ver {
		return 0, 0, 0, 0, 0, nil, ErrBadFrame
	}
	return b[1] & 0x0F, b[2], binary.BigEndian.Uint32(b[4:8]),
		binary.BigEndian.Uint32(b[8:12]), binary.BigEndian.Uint32(b[12:16]), b[HdrLen:], nil
}
