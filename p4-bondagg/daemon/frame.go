package main

import (
	"encoding/binary"
	"errors"
)

// 16-byte agg header, network order:
// [0] magic 0xB0  [1] ver(4b)|flags(4b)  [2] pathID  [3] rsvd
// [4:8] seq32     [8:12] txstamp ms (sender mono, truncated)  [12:16] fseq32
//
// BYTE [3] IS FLAG-SCOPED, NOT FREE (U34a; docs/knowledge/design/
// downlink-routing-spec.md sections 4.0/4.1). Its meaning is selected by the
// flag nibble and by nothing else:
//
//	FlagFEC  -- K, the FEC group size. NO SENDER ON THIS TREE EMITS IT: U128
//	            deleted fec.go and main.go's two parity sites per ADR-002, and
//	            the push tree that did is preserved at tag `eif-push-reference`.
//	            The meaning is recorded because the codepoint stays reserved on
//	            the wire and the flag-space bars still walk it.
//	FlagData -- the DOWNLINK HINT: an unsigned DELTA d. The link the sender asks
//	            the far end to route its downlink onto is (pathID + d) mod 256 --
//	            HintTarget below.
//	anything else -- 0.
//
// WHY A DELTA AND NOT A LINK ID. Every one of the 256 byte values is a legal
// pathID (the wire's own ceiling, server/echo.go MaxLinks = 256), so a bare link
// id has no spare codepoint for "no hint" -- and Pack has always written 0 here,
// so every pre-U34a sender would read as "route everything onto link 0": a fixed
// privileged index, arrived at silently. Under the delta encoding d = 0 resolves
// to (pathID + 0) = pathID, which IS the pre-U34a rule ("follow the link this
// frame arrived on"), so there is no sentinel, no "hint absent" branch, and all
// 256 links stay addressable from any pathID. Old server + hinting client: the
// hint is ignored. New server + old client: d = 0. Neither skew loses a frame
// and neither needs a Ver bump.
//
// The byte is inside the U31 transport MAC (auth.go macLocked covers hdr[:16]),
// so a hint cannot be flipped in flight while the gate is closed. THE PIN IS A
// DIFFERENT TEST IN EACH MODULE, and an earlier draft of this comment said
// "TestMacCoversEveryHeaderByteAndTheLength in both modules", which is false:
// that whole-header single-bit sweep exists ONLY in the server module
// (server/auth_test.go), and this module has no counterpart. In THIS module the
// pin is TestClientHintIsInsideTheTransportMac (hint_test.go), which mints a
// frame carrying a NON-ZERO hint and walks all 255 rewrites of it. Naming a
// test that is not here is the same false-mirror class as server/frame.go's
// "VERBATIM MIRROR" claim that this unit removed (U48; U34a fix round).
//
// seq32 is the GLOBAL resequencer seq for data; on a FlagFEC parity frame it
// carries the group's fseq START (fstart) instead. fseq32 is the PER-PATH frame
// sub-sequence (P5 per-path FEC, design doc §36): every DATA frame on a path is
// numbered contiguously so a per-path parity group is addressable as
// [fstart, fstart+K) in fseq space (members are NOT consecutive global seqs).
// 32-bit so wraparound math matches seq32 (int32 relative compares).
// Non-data frames carry fseq=0.
const (
	Magic = 0xB0
	// Ver 2: the header grew 12->16B (fseq32 added for P5 per-path FEC). Bumping
	// the wire version so a pre-P5 peer (12B header, Ver 1) is REJECTED by Unpack
	// (ver mismatch) instead of silently misparsing the new 16B layout (#8).
	Ver      = 2
	HdrLen   = 16
	FlagData = 0x0
	FlagPing = 0x1
	FlagPong = 0x2
	// FlagFEC was fec.go's, and fec.go is gone (U128, ADR-002: the pull datapath
	// sends no parity). The CODEPOINT stays declared here because it is still
	// wire-reserved and still referenced in code by this module's flag-space
	// bars -- auth_test.go:66 and cap_test.go:273 walk the whole flag nibble
	// 0x0..0x3, and hint_test.go:63,200,205 pins byte [3]'s FEC meaning inside
	// the transport MAC. Deleting the constant would silently shrink those
	// sweeps rather than fail them. Nothing on this tree EMITS a FlagFEC frame:
	// the push tree that did is preserved at tag `eif-push-reference`.
	FlagFEC    = 0x3
	MaxPayload = 1500
	// MaxFrame bounds RX buffers: the largest frame is a parity frame, whose
	// payload carries a 6-byte [seqXOR 4B][xlenXOR 2B] prefix ahead of the XOR
	// body (up to MaxPayload).
	MaxFrame = HdrLen + 6 + MaxPayload
)

var ErrBadFrame = errors.New("bad frame")

// HintTarget resolves a FlagData downlink hint: the link d names, sent on
// pathID. The wrap is mod 256 BY CONSTRUCTION -- both operands and the result
// are byte, which is also why pathID cannot name a link outside the table
// (server/main.go ep is [MaxLinks]*net.UDPAddr, MaxLinks = 256). One function,
// in both modules, so the two ends cannot drift on the arithmetic the way the
// two layout comments did (U48).
func HintTarget(pathID, d byte) byte { return pathID + d }

// Rsvd is header byte [3] of a datagram that has already been through Unpack --
// on a FlagData frame, the downlink-hint delta. Callers must not read it without
// checking the flag: the byte is K under FlagFEC.
func Rsvd(b []byte) byte { return b[3] }

// PackRsvd is Pack with header byte [3] passed explicitly. It exists because
// leaving the byte to be overwritten by the caller after Pack returned is what
// let its meaning go unrecorded: the FEC sites wrote fout[3] = kk over Pack's
// zero (deleted with them in U128), and a design round read the field as
// "unused" from a layout comment
// that had dropped the annotation (U34 round 1's B4, spec section 4.1 item 2).
// rsvd is K on FlagFEC, the downlink-hint delta on FlagData, 0 elsewhere.
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

// Pack is PackRsvd with rsvd = 0, which on a FlagData frame is the hint d = 0 --
// "prefer the link this frame is riding", i.e. exactly the pre-U34a downlink
// rule. Every existing call site therefore keeps emitting the byte it always
// emitted and MEANS by it what the far end already did.
//
// SPEC ITEM 4 IS CLOSED IN THIS MODULE, BY DELETION (U128). It asked
// (downlink-routing-spec.md:509-512) for the rsvd parameter on Pack ITSELF,
// replacing the post-hoc `fout[3] = kk` overwrite at the two FEC sites. U34a
// did half (PackRsvd exists); U128 did the other half by deleting the sites --
// main.go:313/:478 wrote the byte and :220/:611 read it back, and all four were
// inside the push entry points, which ADR-002 removes. `grep -n 'fout\[3\]' *.go`
// is now empty in this module, so nothing here writes byte [3] outside
// PackRsvd. Pack keeps its old signature deliberately: it is the wrapper the
// remaining call sites want (rsvd = 0), and the two modules' signatures are
// kept SYMMETRIC on purpose (U48's layout drift). MEASURED, not assumed: after
// this deletion `grep -n '\[3\] *=' p4-bondagg/{daemon,server}/*.go` outside
// PackRsvd hits only test files, in both modules.
// TestPackThenOverwriteIsPackRsvd (hint_test.go) still pins that the two forms
// are byte-identical for every K, so that rewrite stays provably neutral.
func Pack(dst []byte, flags, pathID byte, seq, tsms, fseq uint32, payload []byte) int {
	return PackRsvd(dst, flags, pathID, 0, seq, tsms, fseq, payload)
}

// UnpackRsvd is Unpack, returning header byte [3] as well. Unpack is kept as the
// 7-value form because every existing reader wants the six fields it always
// wanted; a reader that acts on byte [3] must say so by calling this.
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
