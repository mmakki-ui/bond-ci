package main

import (
	"encoding/binary"
	"errors"
)

// 16-byte agg header, network order. The server is a separate Go module, so the
// layout is duplicated rather than imported: any change to the client header
// MUST be mirrored here or the two peers stop parsing each other.
//
// THIS FILE IS NOT A VERBATIM MIRROR OF daemon/frame.go, AND THE CLAIM THAT IT
// WAS COST A DESIGN ROUND (U48; U34a spec item 5). What is mirrored, exactly:
// the 16-byte LAYOUT, the constants Magic/Ver/HdrLen/MaxPayload/MaxFrame, and
// the bodies of PackRsvd/Pack/UnpackRsvd/Unpack/HintTarget, which are byte for
// byte the client's. What DIFFERS, deliberately: this copy declares FlagFEC and
// FlagEcho (the client declares FlagFEC in fec.go and FlagEcho in cap.go, and
// this server never emits parity), and the per-field commentary below is about
// how the PULL SERVER uses each field. The two are compared by content, not by
// trust: the two Pack/Unpack pairs and the byte [3] semantics are pinned on both
// sides by their own tests. The earlier "verbatim" wording was already false --
// FlagEcho lives only here -- and the specific drift it hid was this copy of the
// layout line dropping the client's "(=K on FlagFEC)" annotation on byte [3],
// which is how U34 round 1 came to record the byte as unused.
//
// [0] magic 0xB0  [1] ver(4b)|flags(4b)  [2] pathID  [3] rsvd
// [4:8] seq32     [8:12] txstamp ms (sender mono, truncated)  [12:16] fseq32
//
// BYTE [3] IS FLAG-SCOPED, NOT FREE (U34a; docs/knowledge/design/
// downlink-routing-spec.md sections 4.0/4.1):
//
//	FlagFEC  -- K, the FEC group size. Dead on this datapath (the RX switch
//	            counts and drops parity) but LIVE in the retained push
//	            reference, which shares the client's copy of this file.
//	FlagData -- the DOWNLINK HINT: an unsigned DELTA d. The link the client asks
//	            this server to route its downlink onto is (pathID + d) mod 256 --
//	            HintTarget below, consumed by peers.route (main.go).
//	anything else -- 0.
//
// The delta encoding, and why it is a delta rather than a link id, is derived in
// full in the client's copy of this comment (daemon/frame.go) and in section
// 4.1(iii) of the spec. The one-line version: every byte value is a legal
// pathID, so a bare id has no "no hint" codepoint, while d = 0 resolves to the
// frame's own path -- which is exactly the pre-U34a downlink rule, so every
// sender that has never heard of the hint already emits the right instruction.
//
// How the pull server uses each field.
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

// HintTarget resolves a FlagData downlink hint: the link d names, sent on
// pathID. The wrap is mod 256 BY CONSTRUCTION -- both operands and the result
// are byte, which is also why no hint can name a link outside the table (ep is
// [MaxLinks]*net.UDPAddr, MaxLinks = 256, echo.go). One function, mirrored in
// both modules, so the two ends cannot drift on the arithmetic the way the two
// layout comments did (U48).
func HintTarget(pathID, d byte) byte { return pathID + d }

// Rsvd is header byte [3] of a datagram that has already been through Unpack --
// on a FlagData frame, the downlink-hint delta. Callers must not read it without
// checking the flag: the byte is K under FlagFEC.
func Rsvd(b []byte) byte { return b[3] }

// PackRsvd is Pack with header byte [3] passed explicitly. See the client's copy
// (daemon/frame.go) for why the post-hoc-overwrite shape was replaced.
func PackRsvd(dst []byte, flags, pathID, rsvd byte, seq, tsms, fseq uint32, payload []byte) int {
	dst[0] = Magic
	dst[1] = (Ver << 4) | (flags & 0x0F)
	dst[2] = pathID
	dst[3] = rsvd
	binary.BigEndian.PutUint32(dst[4:8], seq)
	binary.BigEndian.PutUint32(dst[8:12], tsms)
	binary.BigEndian.PutUint32(dst[12:16], fseq)
	copy(dst[HdrLen:], payload)
	return HdrLen + len(payload)
}

// Pack is PackRsvd with rsvd = 0. On a downlink FlagData frame that is d = 0,
// which the client resolves to the frame's own path -- the server does not hint
// its peer, and this keeps saying so explicitly rather than by omission.
//
// Kept as a wrapper for the reason set out in the client's copy: spec item 4
// wants the parameter on Pack itself, which is a signature change across every
// call site in both modules, and the FEC sites that overwrite the byte after
// Pack returns live in daemon/main.go, outside U34a's owned set. The two
// modules keep the SAME shape here on purpose -- changing one signature and not
// the other would reintroduce exactly the layout drift item 5 just removed.
func Pack(dst []byte, flags, pathID byte, seq, tsms, fseq uint32, payload []byte) int {
	return PackRsvd(dst, flags, pathID, 0, seq, tsms, fseq, payload)
}

// UnpackRsvd is Unpack, returning header byte [3] as well.
func UnpackRsvd(b []byte) (flags, pathID, rsvd byte, seq, tsms, fseq uint32, payload []byte, err error) {
	if len(b) < HdrLen || b[0] != Magic || (b[1]>>4) != Ver {
		return 0, 0, 0, 0, 0, 0, nil, ErrBadFrame
	}
	return b[1] & 0x0F, b[2], b[3], binary.BigEndian.Uint32(b[4:8]),
		binary.BigEndian.Uint32(b[8:12]), binary.BigEndian.Uint32(b[12:16]), b[HdrLen:], nil
}

func Unpack(b []byte) (flags, pathID byte, seq, tsms, fseq uint32, payload []byte, err error) {
	fl, pid, _, sq, ts, fs, pay, e := UnpackRsvd(b)
	return fl, pid, sq, ts, fs, pay, e
}
