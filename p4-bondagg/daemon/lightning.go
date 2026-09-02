package main

// =============================================================================
// U15b / E2c -- STANDING SPOTTY-CLASS LIGHTNING. FLAG-GATED, OFF BY DEFAULT.
//
// The port of PIECE 2 of reserved_composite.py SimD.run (sched='Dc'):
//
//   NOMINATION   every native frame that a SPOTTY-CLASS link actually put on the
//                wire enqueues ONE copy. STANDING: it is an identity rule, not a
//                reaction. There is no duplicate trigger, no loss-rate
//                threshold, no health signal and no "having issues" test -- that
//                whole family is falsified and closed (INTENT.md / the
//                p5-execution-handover.md:49 RULED OUT list: the reactive
//                delivered<sent trigger, adaptive FEC, the always-on mirror,
//                the opportunistic spare-capacity mirror). The win is
//                PRE-EMPTION, so the decision must precede the evidence.
//   ADMISSION    a copy rides only on leftover slack. A STEADY-class host link
//                takes a copy ONLY when the shared native pool has nothing for
//                it at that instant, and only through room(). Native-first IS
//                the damper: copy force is proportional to slack, so it settles
//                itself and no constant is needed to size it.
//   FIRST-WINS   enforced at the PEER's reorder ring, by seq. Nothing in this
//                file does it and nothing in this file may: the ring is the
//                peer's. See "WHERE FIRST-WINS ACTUALLY LIVES" below.
//   TTL          the reorder hold, which is already in use and is not a new
//                number. See "TTL" below for the divergence from the oracle's.
//
// E1 GATE AND FATE. This is the mid-network machinery. It is written either way
// and enabled by the E1 verdict (p5-execution-handover.md:107; the ROADMAP still
// cites :85 for that line, which the E7 amendment shifted), and its fate under an
// `edge` verdict is DELETION, not dormancy: "accept if E1=mid, drop lightning if
// E1=edge" (:47). So it is built to be deletable, but it is FIVE edits, not four:
// this file, lightning_test.go, FOUR lines in pullrun.go (marked U15b), AND the
// `go` job's test floor in .github/workflows/emulator-gate.yml, which must drop
// WITH the deletion commit or the job fails on that commit's own tree (the
// ratchet reads a test count lower than the floor as a dropped file, which is
// exactly what deleting lightning_test.go is). The floor to drop TO is NOT a
// fixed number to copy from this comment -- dev moves, and reusing a stale
// figure here would be the same mistake the ratchet exists to catch elsewhere.
// Recompute it from the tree the deletion commit is actually made against:
// `grep -hc '^func Test' p4-bondagg/daemon/*_test.go` summed over every file
// EXCEPT lightning_test.go (confirm `grep -c 't.Run(' ...` is 0 first, same
// precondition the current floor's derivation already relies on). On this
// branch, merged past U7 and U35, that recompute is 77 (106 total − 29 in
// lightning_test.go, before this round's added test; see Stats/PSTAT tests
// below for the current count). Nothing in pull.go, ring.go, frame.go,
// paths.go or the EIF push stack is touched, and with the flag off the daemon
// runs PullCore.Start -- U7's loop, not this file's.
//
// -----------------------------------------------------------------------------
// WHERE THE CLASSIFICATION COMES FROM, AND WHY NOT FROM THE INTERFACE NAME
// -----------------------------------------------------------------------------
// The class arrives as a FACT in AGG_SPOTTY: an explicit list of device names,
// matched EXACTLY against the AGG_PATHS entries. No name is parsed, no prefix is
// tested, no regexp exists in this file.
//
// The design text names the class as the metered set '^(usb|wwan|rmnet|cell)'
// versus wired '^eth' (p5-execution-handover.md:77). That regexp is NOT what E6
// ships. deploy/p5/bond-xctl:252-274 deleted it and says why: "METERED --
// replaces the '^(usb|wwan|rmnet)' NAME GUESS ... The old regex 'happened' to
// classify usb0 correctly; that was luck, and luck is not a classification."
// What it ships instead is _metered(): an operator fact file
// ($BOND_DIR/metered, one interface or device name per line) with a netifd
// cellular-proto fallback, emitted as the fifth column of gl_sources()
// (bond-xctl:277, "<iface> <l3_device> <state> <metric|-> <metered|->").
// Re-deriving the class from ifname spelling in Go would reintroduce, inside the
// datapath, exactly the guess the control plane removed -- and bond-xctl:146
// states the rule it removed it under: "no interface NAME is ever tested
// anywhere below."
//
// TWO CONSEQUENCES, both stated rather than papered over:
//
//   1. THE FACT IS NOW PLUMBED (fix round, U15b's verify blocker #1). build_agg_env
//      (bond-xctl:634-668) now derives AGG_SPOTTY from the SAME metered column
//      gl_sources already computes (ordered_spotty(), a strict subset of
//      ordered_wans -- it can never name a device outside AGG_PATHS) and emits it
//      unconditionally, same as AGG_PATHS/AGG_W; both the on-demand fallback
//      (act_agg_install) and the canonical deploy/p5/init.d/bond-agg procd stanza
//      pass it through the environment. AGG_LIGHTNING itself is switched by a new
//      operator fact, $BOND_DIR/lightning (same pattern as $BOND_DIR/metered and
//      $BOND_DIR/agg_w) -- absent file is OFF, the same fail-safe default this
//      daemon already applies, so "enablement set by E1" (p5-execution-
//      handover.md:107) now has somewhere to land once E1 measures a verdict.
//      Demonstrated at Layer-2, ecosim/p5/run.sh NG8/NG8b/NG8c (a metered
//      operator fact -> AGG_SPOTTY carries it; the lightning fact -> AGG_LIGHTNING
//      is honoured; no metered fact -> AGG_SPOTTY stays empty, the honest
//      fail-safe, not fabricated).
//      STILL UNTESTED here: that gl_sources' `metered` column is right on real
//      hardware -- no hardware, and Layer-2 exercises the shell artifact under a
//      fixture, not the box's real ubus/netifd.
//
//   2. METERED IS A BILLING PROPERTY AND SPOTTY IS A VARIANCE PROPERTY, and the
//      design equates them without a measurement. bond-xctl:253 says so in its
//      own words -- "Metered-ness is a BILLING property, not a network property".
//      The rig's `spotty` flag is a physical archetype (base/amp/period/dropouts,
//      reserved_composite.py:576-590), not a billing state. A well-behaved LTE
//      line is metered and not spotty; a bad wifi-as-WAN is spotty and not
//      metered. Nothing in the record measures the correlation. Reported as an
//      open question rather than resolved here: the operator fact file is the
//      one place a human can correct it, which is why the fact, not a rule, is
//      the input.
//
// -----------------------------------------------------------------------------
// WHERE FIRST-WINS ACTUALLY LIVES
// -----------------------------------------------------------------------------
// A copy carries the SAME seq as its original. The peer's resequencer is keyed
// by seq, so first-wins is already the peer's behaviour and this daemon adds
// nothing to it:
//   * both in flight, neither released -- server/ring.go:133-136 store():
//     `if e.valid && e.seq == seq { return }`. The SECOND arrival is dropped and
//     the FIRST arrival's timestamp stays in arrQ, so the release schedule is
//     the first copy's.
//   * the loser arrives after release -- server/ring.go:166-177 Push(): it is
//     old, counted in `olds`, and because it is within `mask` of `next` it is
//     explicitly excluded from the seq-space resync run. U16 wrote that carve-out
//     for this case in as many words: "a straggler or a late duplicate copy can
//     never re-anchor the ring backwards" (server/ring.go:36-38).
// So what this unit owes the peer is a PRECONDITION, not a mechanism: at most
// ONE copy per seq, and never on the link that already carried that seq. Both
// are asserted -- TestLightningOneCopyPerSeq, TestLightningCopyNeverRidesOrigin.
// UNTESTED here: the peer half. p4-bondagg/server is U16's module and is not
// compiled by this module's tests; the citations above are reads of that file,
// and no test in this repo drives a copy from this daemon into that ring.
//
// -----------------------------------------------------------------------------
// TTL
// -----------------------------------------------------------------------------
// dupTTL is the reorder hold the control loop already computes and already
// passes to Ring.SetHold and PullFIFO.Trim -- owd.Hold(HoldMin, HoldMax),
// paths.go:74. No number is introduced here.
//
// That is true and, exactly as U7 had to say about the same hold, it is not a
// defence. Two things are wrong with it and neither is this unit's to fix:
//   * the hold itself is on the HANDOFF record as owed a derivation (U13/OBJ-B).
//   * the oracle's dup_ttl is a DIFFERENT formula from the Go hold:
//     min(0.35, max(0.08, (spread + 3*maxjit + 130)/1000)) at
//     reserved_composite.py:193-194, against clamp(spread + 3*jit + 250, 150ms,
//     350ms) at paths.go:102. Same shape, different constants and different
//     clamps. So "TTL == the ring hold" holds in BOTH, and the two rings do not
//     hold for the same length of time. Recorded as a divergence; sizing it is
//     EQ-1 work (U9), not something to guess at here.
//
// -----------------------------------------------------------------------------
// room()
// -----------------------------------------------------------------------------
// The design admits copies "through the SAME room() gate as native". room() is
// the E2b CAP and E2b is U15a, which does not exist on this branch. So room is
// an INJECTED predicate with a documented default:
//   * nil (the default, and what ships until U15a lands): the gate is the SOCKET
//     ITSELF, which is what E2a substituted for the oracle's room() proxy in the
//     first place -- a copy is offered and either the socket takes it or it is
//     shed. Readiness stays OBSERVED. No estimate is consulted, because there is
//     none to consult.
//   * set by U15a: both native and copies pass the same delivered-rate cap, and
//     the composition is the oracle's Dc.
// This hook is NOT a place to put a predictor. The pull pivot's whole content is
// that readiness is observed, not estimated (ADR-002): no rate estimate, no ETA,
// no Smith term, no argmin. Nothing in this file computes one.
//
// -----------------------------------------------------------------------------
// THE POOL BOUND: WHAT A COPY COSTS, AND WHETHER IT CAN EVICT AN ORIGINAL
// -----------------------------------------------------------------------------
// U7's pool sheds OLDEST-FIRST on two limbs (age and bytes) on every mutation
// (pull.go bound()). The question is what duplication does to it.
//
//   A copy NEVER ENTERS THE NATIVE POOL. It lives in this file's own queue, so
//   it contributes ZERO to PullFIFO.bytes, cannot move either limb, and cannot
//   shed any native frame -- original or otherwise.
//   Asserted: TestLightningCopyAddsNothingToPoolBytes,
//   TestLightningCopiesCannotEvictNatives.
//
//   A copy CANNOT EVICT ITS OWN ORIGINAL, and the reason is structural rather
//   than arithmetic: nomination happens AFTER the native write RETURNED sendOK,
//   and Draw already popped that frame out of the pool. The original is gone
//   from the pool before its copy exists. Asserted:
//   TestLightningNominationHappensAfterTheOriginalHasLeftThePool.
//
//   THE ALTERNATIVE DESIGN IS THE ONE THAT SPIRALS, and it is worth naming
//   because it is the obvious implementation. Pushing copies back into the
//   shared FIFO would make each copy occupy pool bytes; being newer than every
//   frame already there, a copy would push the OLDEST frame out, and the oldest
//   frame is by construction an ORIGINAL. Insurance would then destroy the
//   traffic it insures, which is the eviction spiral B4a exists to watch.
//   Not chosen. NOT MEASURED either -- no run in this repo scores that variant.
//
//   THE COST IS REAL BUT IT IS A TIMING COST, NOT AN OCCUPANCY ONE. A host link
//   inside a copy write is not drawing native, so a native that arrives during
//   that write waits for it. Native-first bounds the exposure to ONE write per
//   host link: the check is "the pool had nothing for me at this instant", and
//   the window is the write that follows it. That is a head-of-line delay of one
//   frame per host, and it is the mechanism by which lightning can still deepen
//   the native pool and therefore make its limbs shed more.
//   UNTESTED: the size of that effect. It needs a real device queue and this
//   module has never run on hardware.
//
// -----------------------------------------------------------------------------
// WHAT LIGHTNING DOES TO E1's DISCRIMINATOR -- READ BEFORE RUNNING E1
// -----------------------------------------------------------------------------
// PullLink.send charges blockedNs on any backpressure refusal (pull.go), and
// BlockedMs is E1's edge-vs-mid discriminator. A REFUSED COPY is a refusal, so
// with lightning on, BlockedMs on a host link mixes native refusals with
// insurance refusals and E1's reading is contaminated.
//
// Two things follow, and the first one is the point:
//   * E1 MUST BE MEASURED WITH AGG_LIGHTNING=0, which is the default. E1 gates
//     lightning; lightning must not be present in the measurement that gates it.
//   * a run with lightning on is not silently indistinguishable: copyRefused is
//     counted separately and printed in PSTAT, so the contamination is at least
//     visible after the fact. It is NOT subtracted -- send() is U7's and this
//     unit does not fork it to make a counter look better.
//
// -----------------------------------------------------------------------------
// N-GENERIC
// -----------------------------------------------------------------------------
// N enters as len(core.Links) and nowhere else. The spotty set is a []bool of
// that length, built from a name-set membership test; there is no index 0, no
// primary, no "the tether", no 2-source assumption, and no per-path constant.
// The host set is "every steady, alive, undisabled link" and the copy goes to
// whichever host asks first. Asserted over N in {1,2,3,5,8} and under a
// permutation of which links are spotty:
// TestLightningIsNGeneric, TestLightningIsPermutationSymmetric.
// The wire's one-byte pathID still ceilings N at 256 (MaxLinks, frame.go:9);
// this unit inherits that bound, adds nothing to it and does not re-accept it.
// =============================================================================

import (
	"fmt"
	"log"
	"strings"
	"sync"
	"time"
)

// RoomFn is the E2b CAP's admission gate, injected. nil means "the socket is the
// gate" -- see the room() block in the header. It is called with the pool lock
// NOT held and must not block.
type RoomFn func(l *PullLink) bool

// litCopy is one nominated duplicate awaiting a host.
//
// fr.payload is SHARED with the original frame, not copied again: PullFIFO
// .Enqueue already made an owned copy and nothing in the datapath mutates a
// PullFrame payload after that, so the two frames read the same bytes and the
// copy's reference is what keeps them alive. fr.enq carries the NOMINATION time,
// not the original enqueue time, because the TTL is an exposure window measured
// from the moment the original went out.
type litCopy struct {
	fr  *PullFrame
	src int // the link that carried the native. A host is never this link.
}

// Lightning is the standing spotty-class duplicator. A nil *Lightning is the
// OFF state and every method is nil-safe, so the caller never branches.
type Lightning struct {
	mu       sync.Mutex
	q        []litCopy
	head     int
	n        int
	bytes    int
	maxBytes int
	ttl      time.Duration

	links  []*PullLink
	spotty []bool

	room RoomFn

	// counters. All read and written under mu; PSTAT takes the same lock.
	nominated   uint64 // copies enqueued
	admitted    uint64 // copies actually written
	aged        uint64 // shed by the TTL limb
	overflowed  uint64 // shed by the byte limb
	unarmed     uint64 // native on a spotty link with no eligible host: not nominated
	noRoom      uint64 // a host asked while room() was shut
	copyRefused uint64 // a copy write was refused or failed
	perLink     []uint64
}

// spottyAt reports the CLASS of link i. Out of range is steady, which is the
// inert answer.
func (lit *Lightning) spottyAt(i int) bool {
	if lit == nil || i < 0 || i >= len(lit.spotty) {
		return false
	}
	return lit.spotty[i]
}

// armed mirrors the oracle's `armed = any(at_risk) and any(host)`
// (reserved_composite.py:255). at_risk is spotty AND alive. The oracle's own
// host is stricter than "alive and steady": for sched='Dc' it is
// `host = [alive[i] and not at_risk[i] and s._meter_ok(i) for i in
// range(s.N)]` (:252-253), and _meter_ok (:210-221) is the lagged
// delivered-rate meter -- the same one-sided cap ackclock's 'ewma' uses,
// latched shut on a MID deficit the local socket cannot see and cleared only
// once it drains. THIS daemon's armed() ships alive-AND-steady ONLY; the
// _meter_ok term is missing, not merely unmentioned. It is missing because it
// IS the E2b CAP (U15a's room()), which does not exist on this branch, so this
// unit's eligible-host set is a STRICT SUPERSET of the oracle's until U15a
// lands and is wired through room() -- see the room() block below, where a nil
// gate already documents that the socket substitutes for the missing
// predicate. A link that can never send (no socket, index past the pathID
// ceiling) is neither at_risk nor host.
//
// Both degenerate cases of the design fall out of this one predicate and are
// asserted, not asserted-by-inspection: all-steady nominates nothing
// (TestLightningAllSteadyIsInert), all-spotty admits nothing
// (TestLightningAllSpottyAdmitsNothing).
func (lit *Lightning) armed() bool {
	if lit == nil {
		return false
	}
	var risk, host bool
	for i, l := range lit.links {
		if l.disabled() != "" || !l.Alive() {
			continue
		}
		if lit.spottyAt(i) {
			risk = true
		} else {
			host = true
		}
		if risk && host {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// The copy queue. A ring, oldest at head, exactly like PullFIFO's -- but with
// one deliberate difference in the byte limb, called out in bound().
// ---------------------------------------------------------------------------

func (lit *Lightning) grow() {
	cap0 := len(lit.q)
	if cap0 == 0 {
		cap0 = 16
	} else {
		cap0 *= 2
	}
	nq := make([]litCopy, cap0)
	for i := 0; i < lit.n; i++ {
		nq[i] = lit.q[(lit.head+i)%len(lit.q)]
	}
	lit.q = nq
	lit.head = 0
}

func (lit *Lightning) pushBack(c litCopy) {
	if lit.n == len(lit.q) {
		lit.grow()
	}
	lit.q[(lit.head+lit.n)%len(lit.q)] = c
	lit.n++
}

func (lit *Lightning) popFront() litCopy {
	c := lit.q[lit.head]
	lit.q[lit.head] = litCopy{}
	lit.head = (lit.head + 1) % len(lit.q)
	lit.n--
	return c
}

func (lit *Lightning) peekFront() litCopy { return lit.q[lit.head] }

// bound applies both limbs, oldest-first. Caller holds mu. It runs on EVERY
// mutation -- nominate, take and Tick -- for the same reason U7's does: a bound
// applied only at the 100 ms control cadence is not a bound between ticks.
//
// ONE DELIBERATE DIFFERENCE from PullFIFO.bound. The native pool never empties
// itself below one frame, because refusing all traffic on a box with a tiny
// wmem_default is worse than exceeding the ceiling by one frame. A copy has no
// such claim: it is discardable by construction, so the byte limb here sheds
// down to and including the last copy. Asserted:
// TestLightningByteLimbShedsEvenTheLastCopy.
func (lit *Lightning) bound(now time.Time) {
	if lit.ttl > 0 {
		for lit.n > 0 && now.Sub(lit.peekFront().fr.enq) > lit.ttl {
			c := lit.popFront()
			lit.bytes -= wireBytes(c.fr)
			lit.aged++
		}
	}
	if lit.maxBytes > 0 {
		for lit.n > 0 && lit.bytes > lit.maxBytes {
			c := lit.popFront()
			lit.bytes -= wireBytes(c.fr)
			lit.overflowed++
		}
	}
}

// Nominate is the STANDING rule and it is the whole of the decision: a native
// frame that a SPOTTY-CLASS link actually placed gets ONE copy. Called by
// DriveLit immediately after sendOK.
//
// It reads no rate, no loss, no queue depth and no health signal, and there is
// no branch in it that could become a trigger. The only gates are class
// identity and armed().
//
// Asserted: TestLightningNominatesEverySpottyFrame (no threshold: 100 sends ->
// 100 copies), TestLightningDoesNotNominateOnSteadyLinks.
func (lit *Lightning) Nominate(l *PullLink, fr *PullFrame, now time.Time) {
	if lit == nil || l == nil || fr == nil || !lit.spottyAt(l.idx) {
		return
	}
	if !lit.armed() {
		lit.mu.Lock()
		lit.unarmed++
		lit.mu.Unlock()
		return
	}
	cp := &PullFrame{seq: fr.seq, enq: now, payload: fr.payload}
	lit.mu.Lock()
	lit.pushBack(litCopy{fr: cp, src: l.idx})
	lit.bytes += wireBytes(cp)
	lit.nominated++
	lit.bound(now)
	lit.mu.Unlock()
}

// Take hands the oldest live copy to a host link, or reports that there is none
// for it. It is the ADMISSION half and it is where every eligibility rule lives:
//
//   - a SPOTTY link is never a host (the oracle's `not at_risk`,
//     reserved_composite.py:253). Its own downstream is the thing being insured
//     against, so a copy on it insures nothing.
//   - room() must be open. Default nil == the socket is the gate.
//   - a copy is never handed to the link that carried its original. With a
//     consistent classification that is implied by the first rule; it is checked
//     anyway, because it is the precondition first-wins rests on and a
//     misclassified fact would otherwise silently send both frames down one
//     link.
//
// NATIVE-FIRST is NOT enforced here -- it is enforced by the CALLER, which only
// reaches this function after a non-blocking native draw came back empty. That
// is deliberate: "the pool has nothing for me right now" is a fact only the
// drawer can establish, and establishing it here would need a second look at the
// pool under a second lock.
func (lit *Lightning) Take(l *PullLink, now time.Time) (*PullFrame, bool) {
	if lit == nil || l == nil {
		return nil, false
	}
	if lit.spottyAt(l.idx) || l.disabled() != "" || !l.Alive() {
		return nil, false
	}
	if lit.room != nil && !lit.room(l) {
		lit.mu.Lock()
		lit.noRoom++
		lit.mu.Unlock()
		return nil, false
	}
	// contradictions collects origin-link indices for the log lines below,
	// emitted AFTER mu is released. log.Printf can block on its sink (a slow or
	// wedged syslog, or an unbuffered pipe on the far end), and this is the
	// copy-queue lock -- holding it across a blocking call here would stall
	// every Nominate/Take on every link, in a per-copy loop, for as long as the
	// sink does. TestLightningCopyNeverRidesOrigin exercises the counter and
	// the drop but never the log call's position, so this had no test forcing
	// the question either way.
	var contradictions []int
	lit.mu.Lock()
	lit.bound(now)
	var fr *PullFrame
	ok := false
	for lit.n > 0 {
		c := lit.peekFront()
		if c.src == l.idx {
			// Only reachable if the class fact contradicts itself (this link is
			// both the origin and a host). Shed rather than put two copies of
			// one seq on one link.
			lit.popFront()
			lit.bytes -= wireBytes(c.fr)
			lit.overflowed++
			contradictions = append(contradictions, c.src)
			continue
		}
		lit.popFront()
		lit.bytes -= wireBytes(c.fr)
		fr, ok = c.fr, true
		break
	}
	lit.mu.Unlock()
	for _, src := range contradictions {
		log.Printf("lightning: dropped a copy whose origin link %d (%s) is also "+
			"classified steady -- AGG_SPOTTY contradicts itself; the copy would "+
			"have ridden the link it is insuring against", src, l.ifname)
	}
	return fr, ok
}

// Sent records a copy that reached the wire.
func (lit *Lightning) Sent(l *PullLink) {
	if lit == nil || l == nil {
		return
	}
	lit.mu.Lock()
	lit.admitted++
	if l.idx >= 0 && l.idx < len(lit.perLink) {
		lit.perLink[l.idx]++
	}
	lit.mu.Unlock()
}

// Refused records a copy the socket would not take, or that failed outright.
//
// A refused copy is SHED, not returned to the queue and not retried, and the
// link does NOT park on it. Both halves matter:
//   - shedding is the self-settling property. Copies ride leftover slack; a
//     socket that refuses one is saying there is no slack, and the correct
//     response to "no slack" is to stop, not to queue harder.
//   - not parking keeps insurance from blocking the host's NATIVE work. A copy
//     refusal must never cost a native draw.
//
// Asserted: TestLightningRefusedCopyIsShedNotRequeued,
// TestLightningCopyRefusalDoesNotParkTheHost.
func (lit *Lightning) Refused() {
	if lit == nil {
		return
	}
	lit.mu.Lock()
	lit.copyRefused++
	lit.mu.Unlock()
}

// Tick installs the TTL and applies the bound at the control cadence, exactly
// mirroring PullFIFO.Trim. hold is the SAME owd.Hold the ring and the pool
// already use; see the TTL block in the header for what is and is not settled
// about it.
func (lit *Lightning) Tick(now time.Time, hold time.Duration) {
	if lit == nil {
		return
	}
	lit.mu.Lock()
	lit.ttl = hold
	lit.bound(now)
	lit.mu.Unlock()
}

// Stats returns the counters. Test and PSTAT surface.
func (lit *Lightning) Stats() (depth, qbytes int, nominated, admitted, aged,
	overflowed, unarmed, noRoom, refused uint64) {
	if lit == nil {
		return 0, 0, 0, 0, 0, 0, 0, 0, 0
	}
	lit.mu.Lock()
	defer lit.mu.Unlock()
	return lit.n, lit.bytes, lit.nominated, lit.admitted, lit.aged,
		lit.overflowed, lit.unarmed, lit.noRoom, lit.copyRefused
}

// Stat is the PSTAT fragment. Empty string when lightning is off, so a run with
// the flag down prints exactly what U7 printed.
//
// litsent is per-link and it is printed because PullLink.Sent() COUNTS COPIES
// TOO -- a copy is an ordinary frame on the host's socket and consumes that
// link's fseq like any other. Native sends on link i are Sent(i) - litsent(i);
// without this number that subtraction is not available to anyone reading a log.
//
// ONE lock acquisition, not two. The previous form called Stats() (which takes
// and releases mu) and then took mu again for perLink -- two independent
// snapshots that a concurrent Nominate/Take/Tick could interleave between,
// so a printed PSTAT line could pair depth/counters from one instant with
// litsent from another. Cosmetic (nothing downstream computes on the tear;
// PSTAT is a log line for a human), but free to close.
func (lit *Lightning) Stat() string {
	if lit == nil {
		return ""
	}
	lit.mu.Lock()
	d, qb := lit.n, lit.bytes
	nom, adm, aged, ovf := lit.nominated, lit.admitted, lit.aged, lit.overflowed
	un, nr, ref := lit.unarmed, lit.noRoom, lit.copyRefused
	per := make([]uint64, len(lit.perLink))
	copy(per, lit.perLink)
	lit.mu.Unlock()
	var sb strings.Builder
	fmt.Fprintf(&sb, " | LIT depth=%d qb=%d/%d nom=%d adm=%d aged=%d ovf=%d unarmed=%d noroom=%d refused=%d litsent=",
		d, qb, lit.maxBytes, nom, adm, aged, ovf, un, nr, ref)
	for i, v := range per {
		if i > 0 {
			sb.WriteByte(',')
		}
		fmt.Fprintf(&sb, "%d", v)
	}
	return sb.String()
}

// SetRoom installs the E2b CAP gate. U15a's entry point; nothing else calls it.
// Set ONCE, before Start: it is written bare, on the same terms as txBackoff.
func (lit *Lightning) SetRoom(f RoomFn) {
	if lit == nil {
		return
	}
	lit.room = f
}

// ---------------------------------------------------------------------------
// TryDraw -- the NON-BLOCKING native draw that makes native-first expressible.
//
// It is Draw's empty-pool branch with the wait removed and is otherwise
// identical, accounting included. It lives here rather than in pull.go so that
// deleting lightning deletes it too.
// ---------------------------------------------------------------------------
func (f *PullFIFO) TryDraw() (*PullFrame, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.n == 0 {
		return nil, false
	}
	fr := f.popFront()
	f.bytes -= wireBytes(fr)
	f.drawn++
	return fr, true
}

// ---------------------------------------------------------------------------
// DriveLit -- the draw loop WITH lightning. It is PullLink.Drive with two
// additions and no deletions: a nomination after a successful native send, and
// a copy attempt in the gap where Drive would have blocked.
//
// NATIVE-FIRST IS THE LOOP SHAPE. A copy is only reached after TryDraw comes
// back empty, which is the port of "PIECE 1 has fully drained the pool" -- in a
// single-threaded sim that is a phase, and here it is the per-link instant.
// Asserted: TestLightningNativeFirst (a host with natives queued never takes a
// copy).
//
// KNOWN GAP, bounded and named: if the pool is empty and no host is spinning,
// a copy sits until some link's next pass. The worst case is the control tick's
// Wake (PingIval, already an existing cadence), and the TTL is the ring hold
// (150-350 ms), so a copy can age out while its host is parked on an empty pool.
// That regime is a silent uplink -- no natives means no fresh nominations -- so
// it is the case where a copy matters least, but it is a real hole and it is not
// covered by a wake of its own, because the only honest wake would be a new
// condition variable inside U7's pool.
//
// ALSO NAMED, NOT FIXED: the empty-pool branch reaches lit.Take() BEFORE the
// f.Closed() check that follows it (the blocking f.Draw() fallback below is
// where Closed is tested). So on shutdown with a non-empty copy queue, a host
// link drains its remaining eligible copies to the wire before the next
// f.Draw() call observes Closed and returns. Bounded -- the copy queue is
// bounded on both limbs (bound(), above) -- not a hang, but it is post-close
// wire traffic and no test in this file drives Close() with a nonempty copy
// queue to observe it.
// ---------------------------------------------------------------------------
func (l *PullLink) DriveLit(f *PullFIFO, lit *Lightning) {
	if why := l.disabled(); why != "" {
		log.Printf("pull-link %d dev=%q WILL NOT DRAW: %s. It is excluded from the draw "+
			"set so it can neither dereference a nil socket nor emit a pathID that "+
			"collides with another link (wire ceiling MaxLinks=%d, frame.go:9). N is "+
			"still len(Links); no other link is affected.", l.idx, l.ifname, why, MaxLinks)
		return
	}
	out := make([]byte, MaxPayload+HdrLen)
	for {
		if !l.Alive() {
			if f.Closed() {
				return
			}
			time.Sleep(PingIval)
			continue
		}
		fr, ok := f.TryDraw()
		if !ok {
			// The pool had nothing for this link at this instant: the only
			// moment a copy may be admitted.
			if cp, got := lit.Take(l, time.Now()); got {
				switch l.send(cp, out) {
				case sendOK:
					f.Progress()
					lit.Sent(l)
				default:
					// Refused or failed: SHED. No Return, no backoff, no park --
					// insurance must never cost this link a native draw.
					lit.Refused()
				}
				continue
			}
			// Nothing native, nothing to copy: block exactly as Drive does.
			fr, ok = f.Draw()
			if !ok {
				if f.Closed() {
					return
				}
				continue
			}
		}
		switch l.send(fr, out) {
		case sendOK:
			f.Progress()
			// STANDING NOMINATION. After the write, so the original has already
			// left the pool and a copy can never evict it.
			lit.Nominate(l, fr, time.Now())
		case sendBackpressure:
			f.Return(fr, time.Now())
			l.backoff(f)
			if f.Closed() {
				return
			}
		case sendPathDown:
			// Same honest gap as Drive: between the first path-down error and
			// DeadIval expiring this link keeps drawing and destroying frames.
			// Unchanged here, and not this unit's to close.
		}
	}
}

// ---------------------------------------------------------------------------
// Wiring. Four lines in pullrun.go call into here; everything else is local.
// ---------------------------------------------------------------------------

// NewLightning reads the flag and the class fact and returns the duplicator, or
// nil when lightning is OFF -- which is the DEFAULT.
//
// devs is AGG_PATHS as the caller already split it, so the class fact is matched
// against the same strings the sockets were bound to. No name is parsed.
func NewLightning(c *PullCore, devs []string) *Lightning {
	// U138: OFF under fan-out, unconditionally, whatever the flag says. This
	// duplicator nominates SPOTTY-CLASS frames onto a STEADY host link out of
	// that link's measured slack; under AGG_SCHED=lightning every link already
	// carries every frame, so a copy here would be a copy of a copy -- it could
	// only add a third transmission of a seq the peer has already deduped, and
	// it would charge the host link's BlockedMs (E1's discriminator) for it.
	// There is no "insured" link left to insure.
	//
	// It also keeps DriveLit off the fan-out path: Lightning.Start hands
	// c.FIFO -- the SHARED pool -- to every link, which under fan-out is the
	// wrong (empty) pool. Returning nil here is what makes that line unreachable
	// rather than making it another branch.
	if c != nil && c.Fanout() {
		log.Printf("spotty-class duplicator: OFF -- AGG_SCHED fan-out is on, so every "+
			"source already carries every frame and there is nothing left to duplicate. "+
			"AGG_LIGHTNING=%q is ignored in this mode.", env("AGG_LIGHTNING", "0"))
		return nil
	}
	on := env("AGG_LIGHTNING", "0")
	if on != "1" {
		if on != "0" {
			log.Printf("lightning: AGG_LIGHTNING=%q is not 0 or 1; treating as 0 (OFF)", on)
		}
		// Say nothing more. With the flag down this daemon is U7's pull core and
		// the log should not suggest otherwise.
		return nil
	}
	spottyStr := env("AGG_SPOTTY", "")
	want := map[string]bool{}
	for _, s := range strings.Split(spottyStr, ",") {
		s = strings.TrimSpace(s)
		if s != "" {
			want[s] = true
		}
	}
	lit := &Lightning{
		links:   c.Links,
		spotty:  make([]bool, len(c.Links)),
		perLink: make([]uint64, len(c.Links)),
	}
	nsp := 0
	for i := range c.Links {
		if i >= len(devs) {
			// Structurally impossible via runPullClient (the core is built FROM
			// devs) and therefore never a silent truncation: say so and stop
			// classifying rather than index past the caller's list.
			log.Printf("lightning WARNING: %d links but only %d device names; links "+
				"%d.. are left STEADY because nothing names them", len(c.Links), len(devs), i)
			break
		}
		if want[devs[i]] {
			lit.spotty[i] = true
			nsp++
			delete(want, devs[i])
		}
	}
	for s := range want {
		log.Printf("lightning WARNING: AGG_SPOTTY names %q, which is not in AGG_PATHS. "+
			"It classifies nothing. This is not fatal -- a source can leave the set "+
			"between the fact being written and this daemon starting -- but if it is a "+
			"typo the link it meant is being treated as STEADY and will host copies "+
			"instead of being insured.", s)
	}
	if nsp == 0 {
		log.Printf("lightning: ENABLED but the spotty-class set is EMPTY (AGG_SPOTTY=%q "+
			"over AGG_PATHS=%v). Nothing will be nominated and this is a no-op. The "+
			"class is a FACT, never guessed from the interface name: deploy/p5/bond-xctl "+
			"_metered() owns it (operator file $BOND_DIR/metered, plus netifd cellular "+
			"protos); build_agg_env emits it as AGG_SPOTTY, so an empty set here means "+
			"no source is currently marked metered, not that the fact never arrived.",
			spottyStr, devs)
	} else if nsp == len(c.Links) {
		log.Printf("lightning: ENABLED with %d of %d links spotty-class -- ALL of them. "+
			"There is no steady host, so nothing will be admitted; this degenerates to "+
			"plain pull, which is the designed all-spotty behaviour.", nsp, len(c.Links))
	} else {
		log.Printf("lightning: ENABLED. spotty-class = %d of %d links (fact AGG_SPOTTY=%q). "+
			"STANDING nomination on class identity -- no trigger, no threshold. Copies "+
			"ride only leftover slack (native-first) and first-wins is the peer ring's, "+
			"by seq.", nsp, len(c.Links), spottyStr)
	}

	// ---- the copy queue's BYTE limb. NO DERIVATION EXISTS. Reported. ----
	//
	// The TTL limb is the design's own bound and is honest. The byte limb is
	// only a memory ceiling, and there is no way to derive it here: the useful
	// depth of this queue is (host drain rate x TTL), and a drain-rate estimate
	// is exactly what ADR-002 deleted and what this unit may not reintroduce.
	// So it is NOT derived, it is REUSED -- the pool's own byte bound, itself
	// sum(SO_SNDBUF) (pull.go S3) -- and both that reuse and any override are
	// logged as having no derivation behind them. Same posture as txBackoff.
	lit.maxBytes = c.FIFO.MaxBytes()
	src := "REUSED from the native pool's derived sum(SO_SNDBUF) bound -- a reuse, " +
		"NOT a derivation for this quantity"
	if v := env("AGG_LIGHTNING_MAXQ_BYTES", ""); v != "" {
		var n int
		if _, e := fmtSscan(v, &n); e == nil && n > 0 {
			lit.maxBytes, src = n, "AGG_LIGHTNING_MAXQ_BYTES (operator override, NO derivation)"
		} else {
			log.Printf("lightning: AGG_LIGHTNING_MAXQ_BYTES=%q not a positive int, ignored", v)
		}
	}
	if lit.maxBytes <= 0 {
		log.Printf("lightning: copy-queue byte limb DISABLED (the native pool's byte bound " +
			"is off too, and no AGG_LIGHTNING_MAXQ_BYTES). The queue is bounded in AGE " +
			"only -- by the reorder hold, which is the design's TTL. Depth under a burst " +
			"shorter than that hold is unbounded.")
	} else {
		log.Printf("lightning: copy-queue maxq=%d bytes (%s); age limb = the reorder hold "+
			"(the design's TTL, owd.Hold(%v,%v) -- itself owed a derivation, U13).",
			lit.maxBytes, src, HoldMin, HoldMax)
	}
	log.Printf("lightning: E1 WARNING -- a refused COPY charges the host link's BlockedMs " +
		"(pull.go send), and BlockedMs is E1's edge-vs-mid discriminator. Run E1 with " +
		"AGG_LIGHTNING=0 (the default). LIT refused= in PSTAT is the visible share.")
	return lit
}

// Start launches the draw goroutines: U7's Drive when lightning is off, DriveLit
// when it is on. A nil receiver is the off case, so the caller does not branch
// and the off path is byte-identical to PullCore.Start.
func (lit *Lightning) Start(c *PullCore) {
	if lit == nil {
		c.Start()
		return
	}
	for i := range c.Links {
		go c.Links[i].DriveLit(c.FIFO, lit)
	}
}
