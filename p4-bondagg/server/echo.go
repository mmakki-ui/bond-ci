package main

import (
	"encoding/binary"
	"sync/atomic"
)

// MaxLinks is the wire's OWN ceiling on N: pathID is one byte. It is not a
// tuned limit and not an assumption about how many WANs exist. It is the only
// place a link count appears in the whole server -- N is never configured,
// never defaulted, and index 0 has no special meaning anywhere.
const MaxLinks = 256

// LinkStats is the ONE thing E3 adds to a plain forwarder: per-link CUMULATIVE
// received counters.
//
// COUNTING SEMANTICS, matched to the authoritative oracle (ADR-004),
// p4-bondagg/sim/pull-study/03-reserved-composite/reserved_composite.py:414
// "every arrival turns the meter dial", read together with _lagged_deliv above
// it. Counted at ARRIVAL on the link, before the resequencer. EVERY DATA
// arrival counts -- a duplicate seq (a lightning copy) counts, and an arrival
// the ring later discards as late counts. The meter measures what the LINK
// delivered, never what came out of the ring in order. Control frames are not
// counted; only FlagData is. Bytes are WIRE bytes of the frame as received
// (header + payload), which is exactly the quantity the client put on the wire,
// so its sent_cum and this recv_cum are the same unit and their lag-aligned
// difference is dimensionally exact.
//
// CUMULATIVE and monotone FOR THE PROCESS LIFETIME -- read that literally, it is
// the one place this contract can bite the client. A SERVER RESTART ZEROES THESE
// COUNTERS. A client that blindly differences sent_cum - rxBytes across the
// restart computes inflight ~= sent_cum, which latches its cap PERMANENTLY SHUT:
// exactly the handover caveat-1 failure the txstamp alignment exists to prevent,
// arriving by the other door.
//
// CONTRACT FOR THE CLIENT: treat a counter REGRESSION (a new value below the one
// held for that link) as a re-baseline, not as a difference. Reset the held value
// and skip one interval. Do NOT clamp the difference at zero -- that silently
// hides the restart and holds a stale, too-large inflight.
//
// Never reset and never windowed WITHIN a lifetime. That is the whole point
// (handover section 2): a lost echo costs
// nothing because the next one carries the newer total, so the meter is
// self-healing, where a per-packet credit ledger DEADLOCKS on reverse-path
// loss. The server computes NO rate and holds NO window -- rate and inflight
// are the client's lag-aligned difference against its own sent counters.
type LinkStats struct {
	frames [MaxLinks]uint64
	bytes  [MaxLinks]uint64
}

// OnData records one arrived DATA frame of wireBytes bytes on link.
func (s *LinkStats) OnData(link byte, wireBytes int) {
	atomic.AddUint64(&s.frames[link], 1)
	atomic.AddUint64(&s.bytes[link], uint64(wireBytes))
}

// Frames reports the cumulative DATA frame count for one link (tests, stats).
func (s *LinkStats) Frames(link byte) uint64 { return atomic.LoadUint64(&s.frames[link]) }

// Bytes reports the cumulative DATA wire-byte count for one link.
func (s *LinkStats) Bytes(link byte) uint64 { return atomic.LoadUint64(&s.bytes[link]) }

// ---- echo wire format -------------------------------------------------------
//
// The echo is the payload of a FlagEcho frame sent ONLY in reply to a FlagPing,
// on the same link the ping arrived on, to the ping's own source address.
//
// FlagEcho, not FlagPong: FlagPong is already the CLIENT's 6-byte answer to a
// server ping, and reusing it here at an unchanged Ver=2 makes this payload
// misparse silently in the shipped client. See the FlagEcho comment in
// frame.go for the exact bytes and what each one corrupts.
//
// Two timestamps, each doing a different job:
//
//   header txstamp = the client's ping txstamp, echoed VERBATIM. It lets the
//     client lag-align in ITS OWN clock with no clock sync at all: the reading
//     it is holding cannot be older than the ping it sent at that stamp, so
//     sent_cum(t_echo) - rxBytes is a correctly lag-aligned inflight rather
//     than the un-aligned difference that latches the cap permanently shut
//     (handover caveat 1, the #1 implementation risk).
//
//   payload srvMS = the SERVER's ms at the snapshot instant, uint32.
//     Differencing two consecutive echoes gives the delivered rate with the
//     right denominator -- immune to client/server clock offset (only the
//     interval matters) and immune to reverse-path jitter, which would corrupt
//     a denominator measured in the client's arrival clock.
//
//     TWO CORRECTIONS TO WHAT THIS COMMENT USED TO CLAIM:
//     (a) It is NOT monotonic. nowMS() is time.Now().UnixMilli() (owd.go:11) --
//         WALL clock. An NTP step corrupts exactly one rate denominator. Both
//         peers inherit the same stamp so the two sides stay consistent; the
//         value is simply not monotone. A monotonic source here is a real
//         improvement and is not made in this unit.
//     (b) It WRAPS every ~49.7 days. The client must difference as uint32 and
//         interpret the result as int32, the same wrap-safe idiom the ring uses
//         for seq (ring.go:129,155,166,193). A naive int64 subtraction produces
//         a ~4.29e9 ms denominator once per wrap and reports a delivered rate of
//         approximately zero.
//
// Every link's counters ride in EVERY echo, not just the link the ping came in
// on. That is what keeps the meter alive under reverse-path loss: as long as
// any one link's return direction works, the client still sees every link's
// far-side count. A per-link-only echo would blind the meter for exactly the
// link whose reverse path broke.
//
// payload header, 6 bytes:
//   [0]    nrec    uint8   number of link records that follow
//   [1]    rsvd    uint8   0
//   [2:6]  srvMS   uint32  server monotonic ms at the snapshot instant
// then nrec records of 18 bytes each:
//   [0]     linkID   uint8
//   [1]     rsvd     uint8   0
//   [2:10]  rxFrames uint64  cumulative DATA frames received on linkID
//   [10:18] rxBytes  uint64  cumulative DATA wire bytes received on linkID
//
// Only links that have been SEEN (rxFrames > 0) appear, so the record count is
// the discovered N, in ascending link order.

const (
	echoHdrLen = 6
	echoRecLen = 18
)

// maxEchoRecs is derived, not chosen: the largest whole number of records that
// keeps the complete echo FRAME (header + payload) inside MaxPayload, so the
// reply can never be larger than a data frame the peers already exchange.
const maxEchoRecs = (MaxPayload - HdrLen - echoHdrLen) / echoRecLen

// EchoMaxLen is the largest echo payload Snapshot can write.
const EchoMaxLen = echoHdrLen + maxEchoRecs*echoRecLen

// WHAT THE CLIENT DOES WITH LINKS IT DOES NOT RECOGNISE, and what TRUNCATION
// looks like from the far side. Stated because neither is inferable from the
// bytes:
//
//   * A record for a linkID the client has never sent on is IGNORED. It is not
//     an error: the server reports every link it has SEEN, and a link can be
//     seen because of a stale peer, a restart, or a forged frame.
//
//   * Above maxEchoRecs seen links the snapshot keeps the LOWEST ids, because
//     Snapshot walks 0..MaxLinks-1 ascending and stops at the cap. Links above
//     the cutoff are permanently meter-blind, and nrec carries NO truncation
//     bit, so the client CANNOT distinguish "never seen" from "truncated away".
//     The server counts it (statEchoTrunc) but the wire does not say so.
//
//     This deterministically privileges low link ids, which is in tension with
//     the N-generic rule -- no index is supposed to be special. It is
//     unreachable at the current N (the cap is 82 links against a client that
//     declares 4), so it is recorded here as a known edge rather than fixed by
//     guessing at a fairer policy. Fixing it means a truncation flag in the echo
//     header and a defined selection rule, which is a wire change and needs U7's
//     agreement.

// Snapshot writes the echo payload for every seen link into dst (which must be
// at least EchoMaxLen long) and returns its length. srvMS is the server's
// monotonic ms for the whole snapshot -- one instant for all records.
//
// frames is loaded before bytes, so a record read concurrently with an arrival
// can carry a byte count one frame ahead of its frame count, never behind. The
// client differences BYTES; the frame count is a diagnostic.
func (s *LinkStats) Snapshot(dst []byte, srvMS uint32) int {
	n := 0
	off := echoHdrLen
	for i := 0; i < MaxLinks; i++ {
		f := atomic.LoadUint64(&s.frames[i])
		if f == 0 {
			continue
		}
		if n == maxEchoRecs {
			atomic.AddUint64(&statEchoTrunc, 1)
			break
		}
		b := atomic.LoadUint64(&s.bytes[i])
		rec := dst[off:]
		rec[0] = byte(i)
		rec[1] = 0
		binary.BigEndian.PutUint64(rec[2:10], f)
		binary.BigEndian.PutUint64(rec[10:18], b)
		off += echoRecLen
		n++
	}
	dst[0] = byte(n)
	dst[1] = 0
	binary.BigEndian.PutUint32(dst[2:6], srvMS)
	return off
}

// echoBudget bounds the bonded port's REPLY bytes by the DATA bytes it has
// actually received, so a spoofed-source ping flood cannot use this daemon as a
// reflector: the amplification factor is <= 1 BY CONSTRUCTION, with no rate
// limit to tune and no per-source table to keep. In normal operation data
// outweighs echo by orders of magnitude and the budget never binds; with no
// data there is nothing for the meter to meter, so shedding costs nothing.
type echoBudget struct {
	credit int64
}

func (e *echoBudget) earn(n int) { atomic.AddInt64(&e.credit, int64(n)) }

func (e *echoBudget) spend(n int) bool {
	for {
		c := atomic.LoadInt64(&e.credit)
		if c < int64(n) {
			return false
		}
		if atomic.CompareAndSwapInt64(&e.credit, c, c-int64(n)) {
			return true
		}
	}
}
