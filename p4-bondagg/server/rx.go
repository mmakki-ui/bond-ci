package main

import (
	"net"
	"sync/atomic"
	"time"
)

// rxPath is the uplink receive decision, lifted out of main's socket loop so it
// can be driven by a test with no socket. main() owns exactly one of these and
// calls Handle once per datagram; every buffer it holds is reused, so Handle is
// SINGLE-GOROUTINE by construction, the same as the loop it came from.
//
// It exists because the four forgery vectors in ROADMAP U31 are all decisions
// made here -- which frame gets to move an endpoint, turn the meter, spend the
// echo budget or anchor the ring -- and a decision buried in a `for` loop around
// a UDP socket cannot be tested.
type rxPath struct {
	gate    *authGate
	peers   *peers
	stats   *LinkStats
	bud     *echoBudget
	owd     *OWD
	ring    *Ring
	holdMin time.Duration
	holdMax time.Duration
	echoPay []byte
	echoOut []byte
}

func newRxPath(g *authGate, pr *peers, st *LinkStats, bud *echoBudget, owd *OWD, ring *Ring,
	holdMin, holdMax time.Duration) *rxPath {
	return &rxPath{
		gate:    g,
		peers:   pr,
		stats:   st,
		bud:     bud,
		owd:     owd,
		ring:    ring,
		holdMin: holdMin,
		holdMax: holdMax,
		echoPay: make([]byte, EchoMaxLen),
		echoOut: make([]byte, HdrLen+EchoMaxLen+MacLen),
	}
}

// Handle processes one received datagram from ra and returns the reply to send
// and where to send it, or (nil, nil) for no reply. The returned slice aliases
// rxPath's own buffer and is valid until the next Handle.
//
// THE ORDER OF THE CHECKS IS THE SECURITY PROPERTY. gate.Admit runs FIRST, so a
// frame that cannot authenticate WHILE THE GATE IS CLOSED never reaches the
// endpoint table, the meter, the echo budget or the resequencer. The four
// vectors that closes are each pinned by their own test in auth_vectors_test.go:
// downlink redirect (TestForgedDataFrameCannotRedirectTheDownlink), reflection
// (TestForgedPingCannotReflectToAThirdParty), meter starvation
// (TestForgedPingCannotStarveTheEchoBudget) and the ring re-anchor
// (TestForgedFarSeqCannotReanchorTheRing).
//
// WHILE THE GATE IS OPEN -- no key on the box, or no valid tag inside the reopen
// horizon -- Admit returns admitPass for every well-formed frame and NONE of the
// four is closed. That is the posture of every install today (server/auth.go,
// "WHICH POSTURE CLOSES WHAT"), and each of those four tests carries a positive
// control that runs the same attack against a keyless gate and asserts it still
// SUCCEEDS. Read the controls as the live exposure, not as test scaffolding.
func (x *rxPath) Handle(b []byte, ra *net.UDPAddr, now time.Time) ([]byte, *net.UDPAddr) {
	f, v := x.gate.Admit(b, now)
	switch v {
	case admitMalformed:
		atomic.AddUint64(&statBad, 1)
		return nil, nil
	case admitShed:
		return nil, nil
	}
	switch f.base {
	case FlagData:
		if len(f.pay) == 0 {
			atomic.AddUint64(&statBad, 1)
			return nil, nil
		}
		// METER FIRST, at ARRIVAL, ahead of the ring -- the oracle's semantics
		// verbatim: reserved_composite.py, SimD.run, the line
		//   dk += PKT_KB   # every arrival turns the meter dial
		// CITED BY CONTENT, NOT BY LINE. The earlier form said ":414", which was
		// true only in the worktree it was written in: dev has since changed that
		// file by +3/-55 and the line is 466 there, while 414 now points at a
		// comment inside the duplicate-admission block -- a citation that still
		// resolves and no longer measures the claim. Line numbers in another
		// unit's file rot at every merge; a grep string does not.
		// len(b) is the WHOLE datagram
		// including any tag, which is what the client put on the wire; the
		// client's sent_cum must count its own sealed length for the difference
		// to stay dimensionally exact.
		x.stats.OnData(f.pid, len(b))
		x.bud.earn(len(b))
		// Rsvd(b) is header byte [3], read HERE and only here -- inside the
		// FlagData arm, on a frame gate.Admit has already accepted. Both halves
		// matter: under FlagFEC the same byte is K, and a hint read before Admit
		// would let a forged frame steer the downlink with the gate closed,
		// which is U31 vector 1 reopened. See peers.learn / peers.route (U34a).
		x.peers.learn(f.pid, Rsvd(b), ra, now)
		x.owd.Sample(f.pid, f.ts)
		x.ring.SetHold(x.owd.Hold(x.holdMin, x.holdMax))
		x.ring.Push(f.seq, f.pay, now)
		return nil, nil
	case FlagPing:
		// An AUTHENTICATED ping may move its link's endpoint but NOT the
		// downlink route: the client's NAT binding can rebind between two data
		// frames, and without this the echo would go to a stale address until
		// the next DATA frame. It cannot touch `last`, so it cannot steer the
		// downlink -- that still follows DATA only, which is U16's rule.
		// Pinned by TestAuthenticatedPingRefreshesTheEndpointNotTheRoute.
		if f.authed {
			x.peers.learnEp(f.pid, ra, now)
		}
		// THE ECHO GOES TO THE LEARNED ENDPOINT, NEVER TO THE SOURCE ADDRESS OF
		// THE PING. The old rule replied to the ping's own source (main.go:310
		// before this unit), which made a 16-byte spoofed ping draw up to a
		// 1498-byte echo at an address of the attacker's choosing -- the ~90x
		// per-source amplification ROADMAP records, which the global echo budget
		// did not bound because that budget is an AGGREGATE.
		//
		// WHAT THAT DOES AND DOES NOT BUY, stated exactly, because the first
		// version of this comment claimed reflection was closed unconditionally
		// and it is not:
		//
		//   - GATE CLOSED: reflection is shut. A forged ping never reaches this
		//     code (Admit sheds it) and a forged DATA frame cannot install an
		//     endpoint, so there is no address here an attacker chose.
		//     TestForgedPingCannotReflectToAThirdParty.
		//   - GATE OPEN: reflection is REDUCED, not closed. The ping's source is
		//     no longer an aiming primitive, so a bare spoofed ping only draws an
		//     echo to the real client
		//     (TestDegradedGateRefusesToReflectAtThePingSource). But `ep` is
		//     learned from any well-formed DATA frame (:81 above), so an attacker
		//     who forges ONE DATA frame with the victim as source installs the
		//     victim as this link's endpoint, and every later ping -- 16 bytes,
		//     forged, from anywhere -- draws its echo there.
		//     TestOpenGateReflectsViaAForgedDataFrame demonstrates it end to end.
		//
		// So with the gate open the cost of reflection rises from one spoofed
		// ping to one forged DATA frame, and it becomes LOUD: that same frame is
		// vector 1, so it redirects the client's downlink at the same moment. It
		// is not a separate cheap vector any more. It is not closed either, and
		// no rule available here can close it -- with no key there is nothing
		// that distinguishes the client's DATA frame from a forgery.
		//
		// CONTRACT CHANGE FOR THE CLIENT, and it is a real one: on a link this
		// server has never accepted DATA on, an UNAUTHENTICATED ping now draws
		// NO echo, where before it drew one to its own source. So on a keyless
		// install a link must carry data before its counters appear. That is not
		// a loss the meter can feel -- the echo reports delivered BYTES, and a
		// link that has delivered none has nothing to report -- but it is a
		// change from U16's contract and U7 must not wait on an echo before
		// sending. With a key configured it does not arise: the authenticated
		// ping above learns the endpoint first. Pinned by
		// TestPingOnAnUnknownLinkDrawsNoEcho.
		dst := x.peers.endpoint(f.pid)
		if dst == nil {
			atomic.AddUint64(&statEchoNoEp, 1)
			return nil, nil
		}
		pl := x.stats.Snapshot(x.echoPay, nowMS())
		m := Pack(x.echoOut, FlagEcho, f.pid, 0, f.ts, 0, x.echoPay[:pl])
		if sm := x.gate.Seal(x.echoOut, m, now); sm < 0 {
			// echoOut is HdrLen+EchoMaxLen+MacLen (rx.go:43), so this is
			// unreachable unless someone resizes it. Drop the echo rather than send it with FlagAuth set
			// and no tag, which the peer would shed as a forgery. Counted
			// inside the gate (SealShort, SSTAT).
			return nil, nil
		} else {
			m = sm
		}
		if !x.bud.spend(m) {
			atomic.AddUint64(&statEchoShed, 1)
			return nil, nil
		}
		atomic.AddUint64(&statEchoTx, 1)
		return x.echoOut[:m], dst
	default:
		// FlagPong, FlagFEC, FlagEcho, and every base flag value this build does
		// not know. Admit has already removed the FlagAuth bit, so an
		// authenticated ping arrives here as FlagPing and not as 0x9. Counted,
		// dropped, no state touched.
		atomic.AddUint64(&statIgnored, 1)
		return nil, nil
	}
}
