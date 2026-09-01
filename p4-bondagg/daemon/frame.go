package main

import (
	"encoding/binary"
	"errors"
)

// 16-byte agg header, network order:
// [0] magic 0xB0  [1] ver(4b)|flags(4b)  [2] pathID  [3] rsvd (=K on FlagFEC)
// [4:8] seq32     [8:12] txstamp ms (sender mono, truncated)  [12:16] fseq32
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
	Ver        = 2
	HdrLen     = 16
	FlagData   = 0x0
	FlagPing   = 0x1
	FlagPong   = 0x2
	MaxPayload = 1500
	// MaxFrame bounds RX buffers: the largest frame is a parity frame, whose
	// payload carries a 6-byte [seqXOR 4B][xlenXOR 2B] prefix ahead of the XOR
	// body (up to MaxPayload).
	MaxFrame = HdrLen + 6 + MaxPayload
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
