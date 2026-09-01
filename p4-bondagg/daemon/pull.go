package main

// =============================================================================
// U7 / E2a -- THE PULL CORE (unconditional; settled datapath, ADR-002 + ADR-004).
//
// This file is ADDITIVE. It does not touch the EIF PUSH stack (eif.go, estr.go,
// qtrack2.go, fec.go), which stays as the validated reference and the
// mid-bufferbloat fallback.
//
// WHAT THE PULL CORE IS
//   One shared client send-FIFO. Every WG datagram is stamped with the global
//   resequencer seq AT ENQUEUE (app order) and dropped in the pool. The reader
//   makes NO path decision at all -- that is the whole inversion. Then N link
//   goroutines each DRAW the head frame while they can send. Whoever drains
//   first draws first; share falls out of real drain, it is never computed.
//
// WHAT IT DELIBERATELY DOES NOT CONTAIN
//   No ETA, no Smith predictor, no delivered-rate estimator, no argmin, no FEC,
//   no mirror. The push design's estimator is the thing the pivot removed; it
//   must not reappear here in any form. (p5-execution-handover.md sec 2 / 3 E2a.)
//
// PORT MAP -- p4-bondagg/sim/pull-study/03-reserved-composite/reserved_composite.py
// is the oracle (ADR-004). What is mirrored, function by function:
//
//   SimD.run, the offer block
//       seq = s.next_seq; s.next_seq += 1
//       s.fifo.append(seq); s.enq[seq] = now
//     -> PullFIFO.Enqueue: seq assigned at ENQUEUE, not at draw, so the seq
//        space is app order no matter which link later carries the frame.
//
//   SimD.run, the pool bound
//       while len(s.fifo) * PKT_KB > s.maxq_kb:
//           seq = s.fifo.popleft(); s.qdrops += 1
//     -> PullFIFO.bound, applied at EVERY mutation of the pool (Enqueue, Return
//        and Trim), OLDEST-first, exactly like the oracle's while-loop. It has
//        two limbs, and BOTH run on every enqueue -- this is the point, see S5:
//          age  : drop a frame older than the reorder hold. A frame the receiver
//                 can no longer release in order is dead weight. maxAge is the
//                 caller's existing owd-derived hold (see S4 for its provenance,
//                 which is NOT settled).
//          bytes: the oracle's own limb. maxq_kb = (maxq_ms/1000)*sum(cap0) is a
//                 TIME budget over AGGREGATE NOMINAL CAPACITY. This daemon has no
//                 per-path caps and will not invent them (AGG_W's numbers are
//                 deliberately not inherited), so sum(cap0) has no counterpart
//                 here and the oracle's bound cannot be ported as written. The
//                 substituted default is sum over links of SO_SNDBUF -- MEASURED
//                 from the kernel at start, N-generic, no picked number. It is
//                 NOT the same physical quantity as the oracle's (see S3), it is
//                 the largest local buffering the system has already agreed to
//                 hold for these same sockets. Overridable and logged.
//
//   SimD.run, PIECE 1 (native PULL admission) -- the draw loop itself
//       while s.fifo:
//           cand = [i for i in range(s.N) if room(i)]
//           cand.sort(key=s._local_ms)
//           seq = s.fifo[0]
//           for i in cand:
//               if s.local[i].offer(seq, s.enq[seq], lcaps[i]):
//                   s.fifo.popleft(); ...
//           if not placed: break
//     -> PullLink.Drive. The head frame is the unit and a link that cannot place
//        stops drawing. N enters as the number of Drive goroutines. The pop is
//        NOT the oracle's pop -- see S2, and the ORDER of cand is not the
//        oracle's order -- see S1.
//
//   ackclock_sim.Stage.offer returning False -> the sim tries the next candidate
//   and pops nothing
//     -> the socket refusing the frame (backpressure class, see sendResult).
//        The frame is RETURNED to the pool head rather than dropped, so it stays
//        available to every other link and stays visible to the pool bound. This
//        is a pop-with-rollback, not the oracle's peek-then-pop: S2.
//
//   SimD._local_ms / room(i) for sched='pull'
//       room(i)      = alive[i] and s._local_ms(i) < s.target_ms
//       _local_ms(i) = local[i].backlog_kb / drain_ewma[i] * 1000
//     -> DELIBERATELY NOT PORTED, and this is the one substitution in the file.
//        _local_ms is a backlog/drain-EWMA ESTIMATE that exists only because a
//        simulated socket has no backpressure primitive: Stage.offer taildrops at
//        qmax_ms and nothing else ever says "not now". A real device-bound UDP
//        socket says it directly -- the kernel parks the writer until the device
//        drains. Porting the proxy instead of the real signal would reintroduce
//        exactly the estimator the pivot deleted, and would carry target_ms=40
//        (a picked number) onto hardware. So room(i) here is
//            alive(i)  AND  the socket accepts the write.
//        Both halves are OBSERVED.
//        (SimD._meter_ok / push_est / deliv_hist are E2b, E1-gated -- absent.
//        SimD PIECE 2, the mirror/lightning, is E2c -- absent.)
//        This substitution is what U9/EQ-1 has to adjudicate: the trace harness
//        must drive PullFIFO/Drive with the rig's own admission decisions rather
//        than a socket, or the two cannot be compared frame-for-frame.
//
// =============================================================================
// SUBSTITUTION REGISTER -- what this file does NOT reproduce, and the cost.
// Every entry here is OPEN. None of them is closed by the code below; they are
// written down so nothing downstream reads fidelity into a comment. EQ-1 (U9)
// is the adjudicator for S1 and S2, since both are only visible frame-for-frame.
//
//   S1  DRAW ORDER is not the oracle's order.               [EQ-1 scope]
//       reserved_composite.py @"cand.sort(key=s._local_ms)"  -- HUNGRIEST
//       FIRST: the candidate with the least local backlog-time takes the head
//       frame. Go substitutes the acquisition order of PullFIFO.mu / cv, which
//       is NOT drain order. Go's sync.Mutex BARGES: an already-running goroutine
//       that calls Lock beats a queued waiter, and only after 1 ms of starvation
//       does it hand off FIFO. So under saturation -- the case that matters --
//       the winner is whichever goroutine the scheduler happens to be running.
//       That is arbitrary, not hungriest-first.
//       An earlier revision of this file claimed the sort "collapses into
//       readiness order". That claim holds only when links are IDLE enough to
//       park in cv.Wait, i.e. exactly when the ordering does not matter. It was
//       wrong for the loaded case and has been removed.
//       Why it is not simply fixed: hungriest-first needs a per-link backlog
//       measure, and _local_ms is backlog_kb/drain_ewma -- a rate ESTIMATE. The
//       pivot deleted the estimator. So S1 stays open by construction; it is the
//       same EQ-1 question as room(), and it belongs in that scope.
//       Consequence: share still falls out of real drain in aggregate (a jammed
//       link's write refuses and it stops drawing), but the FRAME-LEVEL sequence
//       of assignments will not match the oracle's, so any EQ-1 comparison must
//       be on distribution, not on a per-frame diff.
//
//   S2  POP-WITH-ROLLBACK, not the oracle's PEEK-then-pop-on-success.
//       reserved_composite.py @"seq = s.fifo[0]; placed = False" is a PEEK; it
//       offers it,
//       and popleft()s only inside the success branch. Draw() below POPS first
//       and send() runs after. This is deliberate: the oracle is single
//       threaded, so a peek can never be raced. Here N goroutines share one
//       pool; a true peek would let two links peek the same head and send the
//       same frame twice, and the only way to prevent that is to hold the pool
//       lock across the write, which serialises all N writes and destroys the
//       whole design. So the pop is a RESERVATION, and Return() rolls it back
//       when the socket refuses (backpressure class).
//       Residual divergence, not closed:
//         (a) for the duration of ONE write attempt the reserved frame is out of
//             the pool and therefore INVISIBLE to the pool bound. The bound is
//             understated by at most N frames -- N * (MaxPayload+HdrLen) bytes.
//         (b) a Returned frame goes back at the HEAD, but another link may
//             already have drawn the frame behind it, so seq can leave in a
//             different order than the oracle would emit. Harmless for
//             correctness (seq is stamped at Enqueue and the receiver reorders
//             within the hold) but it is a real difference in the trace.
//         (c) a frame refused by every link is not dropped by send() at all; it
//             ages in the pool and is shed by the age limb of the bound. Shed
//             accounting therefore moves from the link to the pool.
//
//   S3  THE BYTE BOUND IS NOT THE ORACLE'S BYTE BOUND.
//       Oracle: maxq_kb = (maxq_ms/1000)*sum(cap0) -- a residence TIME budget
//       priced in AGGREGATE NOMINAL CAPACITY. This daemon has no per-path caps
//       and refuses to invent them. Substituted: sum over links of SO_SNDBUF.
//       That IS measured and IS N-generic, but it is a different quantity --
//       kernel socket buffering, not path capacity -- and it has three known
//       distortions:
//         (a) Linux getsockopt(SO_SNDBUF) returns TWICE the value set, the
//             doubling being the kernel's own skb-overhead allowance. So the
//             derived ceiling is roughly 2x the payload bytes the kernel would
//             actually hold. Conservative in the direction of a DEEPER pool.
//         (b) socket buffer size tracks the system default (net.core.wmem_default),
//             which is set by the box, not by the link's capacity. Two links of
//             very different speed contribute the same number.
//         (c) it prices bytes, not time. The age limb is what prices time, and
//             its constant is itself unsettled (S4).
//       So the byte limb is a MEMORY-SAFETY ceiling that happens to be derived
//       from a measurement, NOT a port of the oracle's admission economics.
//       AGG_PULL_MAXQ_BYTES overrides it; the effective value is logged at start.
//       OPEN QUESTION for E1: the right ceiling is a residence-time budget over
//       measured aggregate DELIVERED rate. E1 is the experiment that produces
//       that rate. Until it runs, this is a placeholder with a stated derivation
//       rather than a plausible number, and it should be replaced, not tuned.
//
//   S4  THE AGE LIMB'S CONSTANT IS ON THE OPEN RECORD, AND IS REUSED ACROSS
//       PHYSICAL QUANTITIES.
//       Trim's maxAge is pullrun.go's owd.Hold(HoldMin, HoldMax) =
//       clamp(spread + 3*jit + 250, 150ms, 350ms) (paths.go:102). The +250 and
//       the 150/350 clamp are ALREADY flagged as owed a derivation (HANDOFF
//       2026-08-29, "No arbitrary constants", naming paths.go). Saying "no NEW
//       constant enters" is true and beside the point: the SENDER-side pool
//       depth is now governed by an already-flagged invented constant, and worse,
//       by one measuring a DIFFERENT physical quantity -- Hold is RECEIVER-side
//       reorder spread, and it is being reused as SENDER-side residence. The two
//       coincide only under the argument that a frame older than the receiver's
//       release horizon is undeliverable, which is an argument about the
//       receiver's ring, not about how long a sender should hold work.
//       This is logged as an OPEN divergence. It is not closed by U13's derived
//       hold either: U13 derives the RECEIVER hold. A derived SENDER residence
//       budget is a separate question and nobody owns it yet.
//
//   S5  THE BOUND RUNS AT ENQUEUE, WHICH THE ORACLE DOES TOO -- this one is a
//       FIX, recorded here because the previous revision got it wrong. Before,
//       the only bound was Trim, called once per PingIval=100ms from the control
//       goroutine, so between trims the pool grew unbounded at the WG read rate
//       and no frame younger than the hold was ever dropped at any depth. The
//       oracle bounds on every offer
//       (reserved_composite.py @"while len(s.fifo) * PKT_KB > s.maxq_kb:", inside the
//       per-tick offer block). The push client this replaces made a per-packet
//       admission decision too (main.go:276-279, eif.Pick < 0 -> txdrop), so the
//       gap was a regression against the SHIPPED stack, not only a divergence
//       from the sim. Difference that remains: the push client TAIL-dropped the
//       new frame; the oracle and this file HEAD-drop the oldest. Head-drop is
//       kept because it matches the oracle and because on a resequenced stream
//       the oldest frame is the one closest to being undeliverable anyway.
//
//   S6  THE POOL IS A RING DEQUE, NOT A SLICE.
//       The oracle's fifo is a collections.deque and it uses appendleft on the
//       rollback path. An earlier revision of this file used a Go slice and
//       implemented the rollback as append+copy, i.e. an O(depth) memmove of
//       frame pointers UNDER THE POOL MUTEX, on the ENOBUFS hot path -- the one
//       path that runs most often exactly when the box is most loaded, and the
//       mutex is the one the WG reader's Enqueue and every other link's Draw
//       need. The storage is now a ring with a head index: pushFront, pushBack
//       and popFront are all O(1). The ring GROWS (doubling) and never shrinks,
//       so its allocation high-water is whatever the pool bound permitted; when
//       both limbs are off -- which pullrun.go logs loudly -- it grows with the
//       pool, exactly as the slice did.
//
//   S7  UTILIZATION -- THE PARK CAN IDLE A DEVICE WITH WORK STILL IN THE POOL,
//       AND THAT CONTRADICTS THE HEADLINE WORK-CONSERVING PROPERTY (ROADMAP
//       EPIC 1). The LATENCY cost of the same park is stated below this register;
//       this is the
//       THROUGHPUT one and it is sharper. In the ALL-REFUSING STEADY STATE -- the
//       regime this product is FOR, a saturated edge whose qdiscs are full -- no
//       link is writing, so no link produces Progress, so the only release in the
//       system is the control tick: every link parks for up to PingIval = 100 ms
//       per cycle (main.go:23, Wake at pullrun.go:290) while its device queue
//       drains underneath it. If the queue drains in LESS than PingIval, the
//       device goes IDLE with frames still in the pool, and per-link utilization
//       is about min(1, T_drain / PingIval). That is plausible under this file's
//       own premise of a small txqueuelen (see the WHY "REFUSES" block above):
//       100 packets x 1500 B at 20 Mbps drains in T_drain ~= 60 ms, i.e. roughly
//       a 60% utilization FLOOR at N=1, and the floor is per link, so it does not
//       wash out as N grows. Nothing here fixes it and nothing here may: the
//       corrective is a retry delay shorter than the tick, its derivation needs
//       the device DRAIN RATE, and the drain-rate estimator is exactly what the
//       pivot deleted -- so picking a shorter tick or a backoff constant would be
//       an invented number wearing a derivation's clothes. AGG_PULL_TXBACKOFF_US
//       lets an operator substitute one knowingly; the default stays the park.
//       OPEN QUESTION for E1, stated so the probe can answer it: IS THE QDISC
//       DRAIN TIME SHORTER THAN PingIval ON THE TARGET HARDWARE? E1 already reads
//       BlockedMs / WriteNs / WriteFloorNs per link; the same run answers this,
//       since a device that empties inside the tick shows a saturated link whose
//       BlockedMs is dominated by the park rather than by refused writes. Until
//       it runs, the work-conservation claim holds for the DRAINING case (a
//       successful write releases every parked link immediately, which is what
//       drainLocked's Broadcast is for) and is UNPROVEN for the all-refusing one.
// =============================================================================
//
// N-GENERICITY
//   N is len(Links) and nothing else. No index is privileged, there is no [2],
//   no primary/backup, no first-path fallback, and no per-path constant. A link
//   is described by (ifname, socket) only. The datapath is symmetric under
//   permutation of Links, and the core needs no per-path weights at all -- so it
//   does not inherit AGG_W's two invented numbers.
//
//   ONE CEILING, INHERITED FROM THE WIRE AND RECORDED RATHER THAN ASSUMED.
//   frame.go:9 puts pathID in ONE BYTE of the 16-byte header, so the WIRE can
//   address at most MaxLinks = 256 distinct paths. The symmetry claim above
//   therefore holds for N <= MaxLinks and NOT beyond it. The failure past the
//   ceiling is silent and severe, which is why it is named here: byte(idx)
//   truncates mod 256, so at N=257 links 0 and 256 both emit pathID 0; the peer
//   discovers ONE link where two exist and merges their OWD samples, their
//   LossMeter and -- worst -- their fseq series, so per-path loss is FABRICATED
//   out of two interleaved sub-sequences. The server states the identical bound
//   for the identical reason (p4-bondagg/server/echo.go:8, server/owd.go:22).
//   This is not operationally plausible on this hardware; it is recorded because
//   the rule is "recorded, not silently accepted", and it is ENFORCED in three
//   places rather than only documented: pullrun.go refuses to start, Drive
//   refuses to run such a link, and send() refuses to emit a truncated pathID.
//
// OPEN QUESTION -- carried, not silently resolved (G1/E1 measures it)
//   "The socket accepts the write" is only as tight a gate as SO_SNDBUF makes it.
//   A link whose send buffer is large relative to its drain rate returns to the
//   pool sooner than it has earned and over-draws. No value is picked here: the
//   buffer is left at the system default, its size is LOGGED per link at start,
//   and the send side is instrumented with THREE counters that each mean exactly
//   one thing (see BlockedMs / WriteNs / WriteFloorNs below, and the PSTAT line
//   in pullrun.go). E1 reads the three together; no single one of them is the
//   discriminator, and an earlier revision that claimed one was is corrected.
//
//   WHY "REFUSES" AND NOT "PARKS". The Go netpoller parks a UDP writer only on
//   EAGAIN. Linux does not return EAGAIN when the DEVICE queue is full: it
//   returns ENOBUFS, synchronously, and a blocking socket does not help --
//   udp_sendmsg -> ip_send_skb propagates the qdisc's -ENOBUFS straight back to
//   userspace, it does not sleep for room. On an ARM router with a small
//   txqueuelen that is the NORMAL way edge backpressure appears. There is no
//   kernel primitive that parks a UDP writer on qdisc fullness, so backpressure
//   has to be recognised in the error, not waited on in the syscall. See
//   classifySend / sendResult below.
//
//   OPEN, and NOT resolved by a picked number: how long a link should wait after
//   a backpressure refusal before trying again. The daemon cannot derive it --
//   the derivation needs the device drain rate, and a drain-rate estimate is
//   exactly what the pivot deleted. So the default is still NO INVENTED
//   DURATION. What it does instead of inventing one is WAIT FOR AN EVENT THE
//   SYSTEM ALREADY PRODUCES: PullFIFO.WaitWork parks the refused link on the
//   DRAIN wake set, defined below. AGG_PULL_TXBACKOFF_US still substitutes a
//   real sleep for operators who want one; any nonzero value is an operator's
//   number with no derivation behind it, logged at start.
//   Test: TestPullBackoffOperatorSleepIsChargedToBlocked (the override), and the
//   wake-set tests named below (the default).
//
//   THE DRAIN WAKE SET, and why it is SMALLER than the set of pool changes.
//   Two different waits share this pool and they are NOT waiting for the same
//   thing. A link in Draw waits for POOL CONTENT. A link in WaitWork waits for
//   DRAIN EVIDENCE -- a reason to believe its socket will now accept. Releasing
//   the second on events that only mean the first is a category error, and it is
//   what produced the busy spin twice:
//     * revision A spun on runtime.Gosched and called it "bounded in EFFECT
//       because the refused frame ages out". False: the age limb sheds a FRAME,
//       not the SPIN.
//     * revision B parked on a single generation counter bumped by EVERY pool
//       mutation, INCLUDING Return -- so one refusing link's ROLLBACK released
//       another refusing link, and for N >= 2 two permanent refusers woke each
//       other at CPU speed with no external event at all. The claim in this very
//       block that "the only wake is the control tick" was false for every N
//       except the one N the test suite covered.
//   So the wake sets are now separate, by event class and by condition variable:
//     Draw   (cv,  pool content)  <- Enqueue, Return, Wake, Close
//     WaitWork (dcv, drain evidence) <- Progress, Wake, Close.  NOT Return,
//       which is a rollback and is evidence of nothing draining; NOT Enqueue,
//       because more work in the pool does not make a full qdisc accept a write.
//   Consequence, and it is now the tested claim rather than the asserted one:
//   with every link refusing and the offer idle, NOTHING in the daemon produces
//   a release except the control tick, so the retry rate is bounded by an
//   EXISTING cadence rather than by the CPU -- for every N, not just N=1.
//   Tests: TestPullDriveEveryLinkRefusingDoesNotSpinForAnyN (N in 1,2,3,5 --
//   the whole draw set refusing, no tick, no offer: attempts must not exceed N),
//   TestPullFIFOReturnDoesNotReleaseParkedRefuser,
//   TestPullFIFOEnqueueDoesNotReleaseParkedRefuser,
//   TestPullFIFOProgressReleasesParkedRefuser,
//   TestPullDriveParkedRefuserIsReleasedByWake (the control-tick worst case),
//   TestPullDriveRefusingLinksDoNotStarveHealthyLinkForAnyN (no tick: the refusers'
//   only release is the healthy link's Progress).
//
//   THE RELEASES ARE BROADCASTS, AND UNTIL THIS ROUND NOTHING TESTED THAT.
//   Every test in the list above parks exactly ONE waiter on the condition
//   variable it is asserting, and one waiter cannot tell Broadcast from Signal.
//   Verified by flipping the code, not by reading it. BEFORE the tests below
//   existed, downgrading any of the three -- Progress's dcv.Broadcast, Wake's
//   cv.Broadcast, Wake's dcv.Broadcast -- passed the entire suite. It no longer
//   does: each downgrade now fails its own test. Past tense deliberately; the
//   sentence describes the gap that WAS here, not a property the suite has.
//   So three claims were true of the code and untested, which is the same
//   defect the earlier rounds found, and they are now carried by tests that
//   park a PAIR and fire ONE event:
//     TestPullFIFOProgressReleasesEveryParkedRefuser (Progress -> dcv),
//     TestPullFIFOWakeReleasesEveryParkedRefuser     (Wake    -> dcv),
//     TestPullFIFOWakeReleasesEveryParkedDrawer      (Wake    -> cv),
//   plus the inverse claim, that a pool-content release is exactly ONE drawer and
//   not a thundering herd: TestPullFIFOEnqueueReleasesExactlyOneParkedDrawer.
//   Close's two Broadcasts are already discriminated -- a Signal there strands
//   N-1 goroutines and hangs the wg.Wait in the N=8 and N=5 sweeps.
//
//   UNTESTED, and not claimed: that the park is optimal, that its latency cost
//   under a brief refusal is acceptable, or that any of the above behaves this
//   way on the target hardware. There is no hardware measurement of any of it;
//   E1 is what produces one. The tests above run on a fake socket, so they prove
//   the daemon's own wake logic and nothing about a real qdisc.
//   The THROUGHPUT cost of the same park is the sharper one and it is NOT stated
//   here -- it is S7 in the register ABOVE, because it is a divergence from the
//   work-conserving property this datapath is built on, not a test gap.
// =============================================================================

import (
	"errors"
	"log"
	"net"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// MaxLinks is the wire's OWN ceiling on N: pathID is one byte (frame.go:9,
// header byte [2]). It is not a tuned limit and not an assumption about how many
// WANs exist -- it is a property of this header. It is the only link-count
// CONSTANT in the pull core; every other count in the core is a len() of
// something the operator configured. Identical bound, identical reason, on the
// server side: p4-bondagg/server/echo.go:8.
const MaxLinks = 256

// PullFrame is one enqueued WG datagram. payload is an owned copy: the WG read
// buffer is reused by its reader the instant Enqueue returns.
type PullFrame struct {
	seq     uint32
	enq     time.Time
	payload []byte
}

// Seq is the global resequencer sequence stamped at enqueue.
func (f *PullFrame) Seq() uint32 { return f.seq }

// wireBytes is what one frame costs on the wire, and therefore what it costs
// against the pool's byte bound: its payload plus the fixed header Pack writes.
// Counting payload alone would under-price a small-packet flood, which is the
// shape that fills a device queue fastest.
func wireBytes(fr *PullFrame) int { return len(fr.payload) + HdrLen }

// PullFIFO is THE one shared client send-FIFO. Every link draws from this single
// pool; there is no per-path queue anywhere in the datapath.
//
// It is also the ONLY place the datapath sheds. send() never drops a frame for
// backpressure (S2c), so every shed decision is here, oldest-first, under the
// two-limb bound described in the port map. Both limbs are checked on EVERY
// mutation -- Enqueue, Return and Trim -- not once per control tick (S5).
//
// Storage is a RING with a head index, not a slice: the rollback path pushes at
// the FRONT and must not memmove the pool under the lock. See S6.
type PullFIFO struct {
	mu sync.Mutex
	// TWO condition variables over ONE mutex, because two different waits share
	// this pool and they are not waiting for the same thing. cv is Draw, waiting
	// for POOL CONTENT, and is Signalled by Enqueue and Return. dcv is WaitWork,
	// waiting for DRAIN EVIDENCE, and is Broadcast by Progress.
	// Wake and Close touch both; nothing else touches dcv. Keeping them separate
	// is the whole of the round-4 fix: while they shared one cv and one counter,
	// a Return (a ROLLBACK, evidence of nothing draining) released a link parked
	// on backpressure, so for N >= 2 two permanent refusers woke each other at
	// CPU speed. See the DRAIN WAKE SET block in the header for the tests.
	// rcv is the THIRD wait, added by U17a, and it is separate for exactly the
	// reason dcv is separate from cv: it is waiting for a different thing.
	// A link parked on rcv is not empty-handed and is not refused -- it is a
	// WORSE-RANKED source under AGG_SCHED=speed, waiting for a better-ranked
	// one's gate to CLOSE (rankGate, sched.go). Admitting that release into the
	// drain set would resurrect the round-4 spin in a new costume: two refusing
	// links each publish a gate-close, each release wakes the other, and they
	// spin at CPU speed with no external event. So gate-closes go here and
	// NOWHERE else. With AGG_SCHED=max no gate exists, nothing ever parks on
	// rcv, and this field is untouched for the life of the process.
	cv     *sync.Cond
	dcv    *sync.Cond
	rcv    *sync.Cond
	ring   []*PullFrame
	head   int
	n      int
	seq    uint32
	closed bool

	// drainGen counts DRAIN-EVIDENCE events only -- a successful write on some
	// link, a control-tick Wake, or Close. It exists so WaitWork cannot miss a
	// release that lands between the refusal and the wait. Pool mutations do NOT
	// bump it; that is the point.
	drainGen uint64
	// parked is the number of links currently in WaitWork. Read atomically on
	// the success path so that a run with no refusals pays one uncontended load
	// per frame and never takes this mutex to signal anybody.
	parked int32
	// drawParked is the number of goroutines currently in Draw's cv.Wait. It is
	// OBSERVABILITY ONLY -- nothing in the datapath reads it -- and it exists
	// because without it no test can prove that TWO drawers were parked before a
	// single Wake, which is the only shape that can tell cv.Broadcast apart from
	// cv.Signal. Every drawer test written before it parked exactly one waiter and
	// would have passed under Signal. Maintained exactly like parked: bumped under
	// mu, immediately before cv.Wait releases mu, so a test that has read it can
	// call any pool method and be ordered after the waiter is registered.
	drawParked int32

	// rankGen / rankParked are rcv's pair of the drainGen / parked idiom, with
	// the identical lost-wakeup argument: rankParked is bumped under mu before
	// rankGen is sampled, so any RankChanged that observes rankParked > 0 must
	// block on this mutex until rcv.Wait releases it and its rankGen++ is seen.
	// A RankChanged that observes zero linearised before the link parked, and
	// the wait then ends at the next rank event -- worst case the control tick,
	// never longer. Same as WaitWork, that window is argued from the lock
	// ordering and not executed by a test.
	rankGen    uint64
	rankParked int32

	// bytes is the live wire-byte occupancy of the pool; maxBytes is the byte
	// limb of the bound (0 = limb disabled, and disabled is LOUD: pullrun logs
	// it). maxAge is the age limb (0 = not yet known, i.e. before the first
	// control tick has learned a hold -- the limb is off rather than dropping
	// everything).
	bytes    int
	maxBytes int
	maxAge   time.Duration

	enq    uint64
	drawn  uint64
	stale  uint64
	qdrops uint64
	retq   uint64
	deep   int
	deepB  int
}

func NewPullFIFO() *PullFIFO {
	f := &PullFIFO{}
	f.cv = sync.NewCond(&f.mu)
	f.dcv = sync.NewCond(&f.mu)
	f.rcv = sync.NewCond(&f.mu)
	return f
}

// ---------------------------------------------------------------------------
// Ring primitives. Caller holds mu for all four. They are the whole of S6: the
// pool must accept a push at either end in O(1), because the ENOBUFS rollback
// pushes at the front and it runs on the hot path under this mutex.
// ---------------------------------------------------------------------------

// grow doubles the ring and re-lays the live frames from index 0. It is the only
// allocation on the pool path. The ring never shrinks: its high-water is bounded
// by whatever the pool bound permitted, and if both limbs are off the pool is
// unbounded anyway (pullrun.go says so, loudly).
func (f *PullFIFO) grow() {
	c := len(f.ring)
	nc := c * 2
	if nc < 8 {
		nc = 8
	}
	nr := make([]*PullFrame, nc)
	for i := 0; i < f.n; i++ {
		nr[i] = f.ring[(f.head+i)%c]
	}
	f.ring = nr
	f.head = 0
}

func (f *PullFIFO) pushBack(fr *PullFrame) {
	if f.n == len(f.ring) {
		f.grow()
	}
	f.ring[(f.head+f.n)%len(f.ring)] = fr
	f.n++
}

func (f *PullFIFO) pushFront(fr *PullFrame) {
	if f.n == len(f.ring) {
		f.grow()
	}
	f.head = (f.head - 1 + len(f.ring)) % len(f.ring)
	f.ring[f.head] = fr
	f.n++
}

func (f *PullFIFO) popFront() *PullFrame {
	fr := f.ring[f.head]
	f.ring[f.head] = nil
	f.head = (f.head + 1) % len(f.ring)
	f.n--
	return fr
}

func (f *PullFIFO) peekFront() *PullFrame { return f.ring[f.head] }

// SetMaxBytes installs the byte limb of the pool bound. n <= 0 disables the
// limb. The value is NOT chosen here and NOT defaulted here: pullrun.go derives
// it (sum of SO_SNDBUF over links, or AGG_PULL_MAXQ_BYTES) and logs it, so the
// provenance of the number lives at the one place that can state it. See S3.
func (f *PullFIFO) SetMaxBytes(n int) {
	f.mu.Lock()
	f.maxBytes = n
	f.bound(time.Now())
	f.mu.Unlock()
}

// MaxBytes reports the installed byte limb.
func (f *PullFIFO) MaxBytes() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.maxBytes
}

// bound is the oracle's pool bound
// (reserved_composite.py @"while len(s.fifo) * PKT_KB > s.maxq_kb:"), oldest-first,
// with the two limbs described in the port map. Caller holds mu.
//
// The byte limb never empties the pool below one frame: a single frame larger
// than maxBytes is admitted rather than discarded, because dropping it would
// make the pool refuse ALL traffic on a box with a tiny wmem_default, which is a
// worse failure than exceeding the ceiling by one frame. That is a bounded
// overshoot of at most one MaxPayload+HdrLen, stated rather than hidden.
func (f *PullFIFO) bound(now time.Time) (aged, over int) {
	if f.maxAge > 0 {
		for f.n > 0 && now.Sub(f.peekFront().enq) > f.maxAge {
			f.bytes -= wireBytes(f.popFront())
			f.stale++
			aged++
		}
	}
	if f.maxBytes > 0 {
		for f.n > 1 && f.bytes > f.maxBytes {
			f.bytes -= wireBytes(f.popFront())
			f.qdrops++
			over++
		}
	}
	return aged, over
}

// content is the "pool content changed" release: exactly one frame became
// available, so exactly one drawer is released. It is a plain Signal and it
// carries no generation bump, because Draw re-reads n under the mutex and a
// waiter parked on backpressure is not on this condition variable at all.
//
// Call AFTER unlocking. An earlier revision used one shared cv here and had to
// upgrade to Broadcast whenever a link was parked on backpressure, precisely
// because the two waiter classes were mixed; separating them removed both the
// upgrade and the spin it was papering over.
//
// "EXACTLY ONE" is now asserted rather than asserted-by-inspection, and it needs
// TWO parked drawers to mean anything: with one, Signal and Broadcast are
// indistinguishable. Test: TestPullFIFOEnqueueReleasesExactlyOneParkedDrawer.
func (f *PullFIFO) content() { f.cv.Signal() }

// drainLocked records DRAIN EVIDENCE (or shutdown) for links parked in
// WaitWork. Caller holds mu; caller Broadcasts dcv after unlocking. It is a
// Broadcast, not a Signal: one device draining is evidence for every parked
// link, and each re-evaluates its own socket.
//
// EVERY is the load-bearing word and it needs N >= 2 parked to be a claim at
// all. Every test that asserted a dcv release before this round parked exactly
// ONE refuser, so all of them passed under Signal -- the code had the property
// and nothing tested it. Test: TestPullFIFOProgressReleasesEveryParkedRefuser
// (two refusers, ONE Progress, both must release).
func (f *PullFIFO) drainLocked() { f.drainGen++ }

// Enqueue copies payload into the pool and stamps it with the next global seq.
// Mirrors reserved_composite.py SimD.run's offer block: seq is assigned HERE, in
// app order, before any link has looked at the frame -- and the pool bound is
// applied HERE too, on the same offer, exactly as the oracle applies it inside
// the offer block
// (reserved_composite.py @"while len(s.fifo) * PKT_KB > s.maxq_kb:"). That is what
// makes the pool
// bounded at the WG read rate rather than at the 100 ms control cadence (S5).
//
// It still returns a seq unconditionally and cannot refuse. The oracle cannot
// refuse an offer either -- it head-drops to make room. The shed is real, it is
// just applied to the OLDEST frame rather than to this one; qdrops/stale count
// it and PSTAT prints both.
func (f *PullFIFO) Enqueue(payload []byte, now time.Time) uint32 {
	cp := make([]byte, len(payload))
	copy(cp, payload)
	f.mu.Lock()
	s := f.seq
	f.seq++
	fr := &PullFrame{seq: s, enq: now, payload: cp}
	f.pushBack(fr)
	f.bytes += wireBytes(fr)
	f.bound(now)
	if f.n > f.deep {
		f.deep = f.n
	}
	if f.bytes > f.deepB {
		f.deepB = f.bytes
	}
	f.enq++
	f.mu.Unlock()
	f.content()
	return s
}

// Draw removes and returns the head frame, blocking while the pool is empty.
//
// ok=false means "nothing drawn, re-check your own gates and call again" -- the
// pool was empty when this waiter was woken (by Wake, by Close, or because
// another link took the frame first). The caller consults Closed to decide
// whether to exit.
//
// A drawn frame is RESERVED to that link, not committed: the oracle PEEKS and
// pops only on success, and this pops and rolls back via Return on a
// backpressure refusal. The difference and its residue are S2 in the register
// above -- do not read this as the oracle's pop.
func (f *PullFIFO) Draw() (*PullFrame, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.n == 0 {
		if f.closed {
			return nil, false
		}
		atomic.AddInt32(&f.drawParked, 1)
		f.cv.Wait()
		atomic.AddInt32(&f.drawParked, -1)
		if f.n == 0 {
			return nil, false
		}
	}
	fr := f.popFront()
	f.bytes -= wireBytes(fr)
	f.drawn++
	return fr, true
}

// Return rolls back a Draw whose socket refused the frame (backpressure class).
// It is the rollback half of S2: the frame goes back at the HEAD keeping its
// ORIGINAL enq stamp, so it is once again visible to the pool bound and to every
// other link, and it ages on the clock it was offered on rather than on the
// clock it was refused on. A frame no link will take is therefore shed by the
// age limb of the bound, not by the link -- send() never drops for backpressure.
//
// The returned frame is re-bounded immediately, so a Return into a full pool
// sheds oldest-first like any other mutation. A Return can therefore drop the
// very frame being returned only when it is itself the oldest and over-age,
// which is the correct outcome.
//
// It is O(1): the pool is a ring and this is a pushFront. See S6 for why that
// matters -- this runs on the ENOBUFS path, under the mutex the WG reader and
// every other link need.
//
// It releases a DRAWER (one frame is available again) and it must NOT release a
// link parked on backpressure: a rollback is not evidence that any device is
// draining. While it did, one refuser's Return woke another refuser and the two
// spun against each other for every N >= 2. See the header's DRAIN WAKE SET.
// Test: TestPullFIFOReturnDoesNotReleaseParkedRefuser covers the NEGATIVE half
// (no refuser is released). The positive half -- that Return does wake a parked
// DRAWER -- is UNTESTED: no test parks a drawer and calls Return.
// TestPullDriveReturnsRefusedFrameAndPlacesItLater does not cover it either; its
// re-draw is driven by the test's own tickWake, not by Return's content() signal.
func (f *PullFIFO) Return(fr *PullFrame, now time.Time) {
	if fr == nil {
		return
	}
	f.mu.Lock()
	f.pushFront(fr)
	f.bytes += wireBytes(fr)
	f.retq++
	if f.drawn > 0 {
		f.drawn--
	}
	f.bound(now)
	f.mu.Unlock()
	f.content()
}

// Trim applies the pool bound at the control cadence AND installs maxAge, the
// age limb, so that Enqueue and Return can apply the same limb between ticks.
// It returns how many frames the age limb shed, preserving its original meaning.
//
// maxAge is not a NEW constant -- the caller passes the same owd-derived reorder
// hold it feeds the ring -- but it is not a settled one either, and it is being
// used for a different physical quantity than it was derived for. See S4.
func (f *PullFIFO) Trim(now time.Time, maxAge time.Duration) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.maxAge = maxAge
	aged, _ := f.bound(now)
	return aged
}

// Wake is the control cadence, and it is the ONE event that belongs to BOTH
// wake sets: it releases every blocked drawer so it can re-evaluate its own
// liveness gate, and it is the worst-case release for a link parked on
// backpressure. It is not a datapath event.
//
// Because it is the only release a fully-refusing draw set ever gets, it is
// what makes the retry rate bounded by an existing cadence.
//
// BOTH releases are Broadcasts and both need N >= 2 waiters to be discriminated
// from a Signal. The two single-waiter tests below were written first and pass
// under either, so they are kept as the shape assertions and the EVERY claim is
// carried by the two that park a pair. Under cv.Signal, N parked drawers
// re-evaluate their liveness gate over N ticks instead of one; under dcv.Signal,
// N parked refusers retry over N ticks -- N-1 links idle for up to N*PingIval
// while the pool holds work (see S7).
// Tests: TestPullFIFOWakeReleasesEveryParkedDrawer (the Draw half, two drawers,
// ONE Wake), TestPullFIFOWakeReleasesEveryParkedRefuser (the WaitWork half, two
// refusers, ONE Wake), TestPullFIFOWakeReleasesParkedDrawer and
// TestPullDriveParkedRefuserIsReleasedByWake (the single-waiter shapes).
// U17a adds the THIRD release: a link deferring to a better-ranked one. Wake is
// its worst-case release too, and for the same reason -- it is the one event
// that belongs to every wake set, so no wait in this file can outlive one
// control tick without an external event.
func (f *PullFIFO) Wake() {
	f.mu.Lock()
	f.drainLocked()
	f.rankGen++
	f.mu.Unlock()
	f.cv.Broadcast()
	f.dcv.Broadcast()
	f.rcv.Broadcast()
}

// WaitRank parks a link that MAY NOT DRAW because a better-ranked eligible link
// exists (AGG_SCHED=speed only; `max` installs no gate and never calls this).
// It returns on a rank event -- some link's gate closed, the control tick, or
// close -- and introduces no duration of its own.
//
// It is NOT the drain set and must never be merged with it. A deferring link is
// not refused: its socket would take a frame right now. Waking it on drain
// evidence would defeat the whole policy (the better link draining is exactly
// the reason to keep deferring), and waking a REFUSED link on a rank event would
// let two refusers spin against each other, which is the round-4 bug this file
// already carries the scar of.
//
// The worst case is one control tick, the same bound WaitWork carries, and it is
// bounded for every N rather than for the one N a test happened to cover:
// nothing in the datapath produces a rank event when every link is deferring,
// and every link deferring is impossible anyway -- the strict-better relation
// leaves at least one eligible link ungated (sched.go, Better, point 3).
func (f *PullFIFO) WaitRank() {
	f.mu.Lock()
	atomic.AddInt32(&f.rankParked, 1)
	g := f.rankGen
	for f.rankGen == g && !f.closed {
		f.rcv.Wait()
	}
	atomic.AddInt32(&f.rankParked, -1)
	f.mu.Unlock()
}

// RankChanged is called by a link whose GATE JUST CLOSED -- it was refused by
// its socket, its cap latched, or it went dead. That is the only event that can
// make a worse-ranked link eligible to draw, and it is edge-triggered: the
// caller publishes the transition, not the condition, so a link that stays
// refused forever produces exactly ONE of these.
//
// It costs one uncontended atomic load when nothing is deferring, which is the
// normal case and the whole of the `max` cost (where nothing ever defers).
func (f *PullFIFO) RankChanged() {
	if atomic.LoadInt32(&f.rankParked) == 0 {
		return
	}
	f.mu.Lock()
	f.rankGen++
	f.mu.Unlock()
	f.rcv.Broadcast()
}

// RankParked is the number of links currently deferring. OBSERVABILITY ONLY --
// nothing in the datapath reads it -- and it exists for the same reason
// drawParked does: without it no test can park TWO waiters before firing ONE
// event, which is the only shape that tells rcv.Broadcast from rcv.Signal.
func (f *PullFIFO) RankParked() int32 { return atomic.LoadInt32(&f.rankParked) }

// Progress is called by a link whose write JUST SUCCEEDED. A successful write is
// the only direct evidence this daemon has that a device is actually draining,
// and it is the ONLY datapath event in the drain wake set. Return is not in it:
// a rollback is evidence of nothing, and admitting it is what let two refusing
// links wake each other. Enqueue is not in it either: more work in the pool does
// not make a full qdisc accept a write.
//
// It costs one uncontended atomic load when nothing is parked, which is the
// normal case: the pool mutex is not taken and no waiter is signalled.
// Tests: TestPullFIFOProgressReleasesEveryParkedRefuser (the EVERY claim: two
// refusers, ONE Progress, both must release -- the only shape that separates
// Broadcast from Signal here), TestPullFIFOProgressReleasesParkedRefuser (the
// single-waiter shape), TestPullFIFOReturnDoesNotReleaseParkedRefuser and
// TestPullFIFOEnqueueDoesNotReleaseParkedRefuser (they do not),
// TestPullDriveRefusingLinksDoNotStarveHealthyLinkForAnyN (end to end, no tick: a
// healthy link's Progress is the refuser's only release -- note that this one
// does NOT discriminate the Broadcast either: the healthy link drains regardless
// of how many refusers a Progress releases, and Close's own Broadcast unparks the
// rest at the end).
func (f *PullFIFO) Progress() {
	if atomic.LoadInt32(&f.parked) == 0 {
		return
	}
	f.mu.Lock()
	f.drainLocked()
	f.mu.Unlock()
	f.dcv.Broadcast()
}

// WaitWork parks a link that has just been REFUSED by its socket until DRAIN
// EVIDENCE appears: some other link writes successfully, the control tick Wakes,
// or the pool closes. It returns immediately on a closed pool. It does NOT wait
// on pool content -- see Progress and the header's DRAIN WAKE SET block.
//
// This is what replaces the busy spin, and it introduces no duration: the wait
// ends on an event the system already produces. Worst case -- every link in the
// draw set refusing and the offer idle -- the only such event is the control
// tick, so the retry rate is bounded by an EXISTING cadence instead of by the
// CPU. That is asserted for N in {1,2,3,5} by
// TestPullDriveEveryLinkRefusingDoesNotSpinForAnyN; the previous revision
// asserted it only at N=1, which was the only N at which it was true.
//
// parked is bumped INSIDE the lock, before drainGen is sampled. That ordering is
// what closes the lost-wakeup window: any Progress that observes parked > 0 must
// then block on this mutex until dcv.Wait releases it, so its drainGen++ lands
// after the sample and is seen. A Progress that observes parked == 0 linearised
// before this link parked at all, and the wait then ends at the next drain event
// -- worst case the control tick, never longer.
// UNTESTED: that window is argued from the lock ordering, not executed. A test
// that lands a Progress exactly between the refusal and the Wait would have to
// control goroutine interleaving, which this package cannot do; the control tick
// is what bounds the damage if the argument is wrong.
func (f *PullFIFO) WaitWork() {
	f.mu.Lock()
	atomic.AddInt32(&f.parked, 1)
	g := f.drainGen
	for f.drainGen == g && !f.closed {
		f.dcv.Wait()
	}
	atomic.AddInt32(&f.parked, -1)
	f.mu.Unlock()
}

// Close stops every drawer AND every parked refuser, so no goroutine is
// stranded on either condition variable.
// Tests: TestPullFIFOCloseReleasesDrawers, and every Drive test above ends with
// Close and asserts the goroutine exits.
func (f *PullFIFO) Close() {
	f.mu.Lock()
	f.closed = true
	f.drainLocked()
	f.rankGen++
	f.mu.Unlock()
	f.cv.Broadcast()
	f.dcv.Broadcast()
	// U17a: a link deferring to a better-ranked one is stranded by a Close that
	// forgets this line, and a stranded goroutine hangs the wg.Wait in the
	// high-N sweeps rather than failing anywhere legible.
	f.rcv.Broadcast()
}

func (f *PullFIFO) Closed() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.closed
}

// Stats reports current depth, high-water depth, and the cumulative enqueue /
// net-draw / age-shed counts. drawn is NET of Return: a frame the socket refused
// is un-drawn, so drawn stays "frames that left the pool for good".
func (f *PullFIFO) Stats() (depth, peak int, enq, drawn, stale uint64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.n, f.deep, f.enq, f.drawn, f.stale
}

// ByteStats reports the byte limb: live occupancy, high-water occupancy, the
// installed ceiling, the frames shed BY THE BYTE LIMB (distinct from stale,
// which is the age limb), and the number of backpressure rollbacks. Separate
// from Stats so the two limbs are never confused in a log line.
func (f *PullFIFO) ByteStats() (bytes, peakBytes, max int, qdrops, returns uint64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.bytes, f.deepB, f.maxBytes, f.qdrops, f.retq
}

// linkSocket is THE SEAM. It is the narrowest interface the pull core needs from
// a bound UDP socket, and it exists so the send path -- the ENOBUFS
// classification, the rollback, the fseq discipline and the blocked accounting
// -- can be driven by a fake that returns a chosen sequence of errnos. Before it
// existed, PullLink held a concrete *net.UDPConn and NOTHING in the test suite
// could execute Drive, send or the backoff at all: the remediation for the
// ENOBUFS defect was entirely unasserted, and every COMPOSED claim about it was
// true only by inspection.
//
// *net.UDPConn satisfies it as written. SyscallConn is in the interface rather
// than kept as a second concrete field because a typed-nil *net.UDPConn stored
// in an interface is a NON-nil interface, and that trap is worse than one extra
// three-line method on the fake.
type linkSocket interface {
	WriteToUDP(b []byte, addr *net.UDPAddr) (int, error)
	SyscallConn() (syscall.RawConn, error)
}

// PullLink is one WAN source: an ifname and the socket bound to it. It holds no
// rate, no ETA, no queue and no estimate -- it is purely a drawer.
//
// FIELD ORDER IS LOAD-BEARING. The 64-bit counters are accessed with sync/atomic
// and must be 8-byte aligned. On the armv7 crossbuild target
// unsafe.Alignof(int64) is 4, so a 64-bit field placed after the 4-byte fields
// can land 4-byte aligned and atomic.LoadInt64 PANICS at run time. Only "the
// first word in an allocated struct" is guaranteed 64-bit aligned, so the eight-
// byte counters are kept contiguous at the top. Do not interleave them with the
// narrow fields. (main.go sidesteps this by holding its int64 counters in a
// []int64, whose elements are aligned by construction.)
type PullLink struct {
	lastRxMs  int64
	blockedNs int64
	okWriteNs int64
	minOkNs   int64
	sent      uint64
	bytes     uint64
	errs      uint64
	bpress    uint64
	// U17a. deferNs/defers are the `speed` rank gate's accounting, and they are
	// their OWN pair rather than a fold into blockedNs for the same reason
	// CapStats.Refusals is separate: blockedNs means "the device would not take
	// a frame" and is E1's edge discriminator, while a rank deferral is this
	// daemon's own policy declining to OFFER one. Folding them would make a
	// deferring link read exactly like edge backpressure in the measurement E1
	// depends on. Zero on every `max` run.
	deferNs int64
	defers  uint64

	idx    int
	ifname string
	sock   linkSocket
	dst    *net.UDPAddr
	fseq   uint32
	alive  int32
	// gateClosed is this link's OWN answer to "would I take a frame right now",
	// published for the rank gate to read and written by nobody else. It is
	// edge-published (setGateClosed reports the transition) so a permanently
	// refusing link produces one rank event, not one per retry.
	//
	// MAINTAINED ONLY WHEN A GATE IS INSTALLED. With AGG_SCHED=max, l.gate is
	// nil, nothing reads this, and Drive does not write it -- the `max` hot path
	// carries one nil check and not one extra atomic.
	gateClosed int32

	// cap is the E2b delivered-rate gate (cap.go). NIL IS THE NORMAL STATE and
	// the shipped default: PullCore.SetCap installs one only when
	// AGG_PULL_CAP=on, and every Cap method tolerates a nil receiver, so with the
	// flag off the gate below costs one nil-check per draw and can never refuse.
	// Written once, before Start; never mutated after.
	cap *Cap

	// gate is the U17a draw gate. NIL IS `max` AND IS THE DEFAULT:
	// PullCore.SetSched installs one only for AGG_SCHED=speed, so with `max` the
	// draw loop is U7's, unmodified, behind one nil check. Written once, before
	// Start, for the same reason cap is: the draw path reads it without
	// synchronisation and the scheduler is a start-time fact (a mode flip is an
	// agg_env byte change -> crumb -> restart, bond.dag).
	gate SchedGate
}

// sendResult classifies the outcome of one write. The split exists because the
// two failure classes mean OPPOSITE things about the link and must not share a
// counter or a policy.
type sendResult int

const (
	// sendOK: the socket took the frame. Committed to this link.
	sendOK sendResult = iota
	// sendBackpressure: the device or the kernel has no room RIGHT NOW. The link
	// is healthy, the path is up, and the frame was NOT sent. It must not be
	// dropped here (S2c) and the time must be charged to the blocked accounting,
	// because this IS the edge-bottleneck refusal signal E1 reads.
	sendBackpressure
	// sendPathDown: the write failed for a reason retrying cannot fix -- no
	// route, no host, no device, bad address, or a link this daemon refuses to
	// run at all (no socket, or an index past the wire's pathID ceiling). The
	// frame is consumed and lost; liveness (RxAge/DeadIval) is what takes the
	// link out of the draw set.
	sendPathDown
)

// classifySend splits write errors into the backpressure class and everything
// else. It matches ERRNOS with errors.Is, never error strings: Go wraps the
// errno in *net.OpError -> *os.SyscallError -> syscall.Errno, errors.Is unwraps
// to the Errno and compares, and the text of these messages is not a stable
// interface.
//
// Backpressure class:
//
//	ENOBUFS  the qdisc / device queue is full. THE case this exists for: on a
//	         router with a small txqueuelen this is how edge backpressure
//	         normally appears, and the netpoller never sees it because it is not
//	         EAGAIN. Treating it as an error dropped the frame and left the
//	         refusal unrecorded in exactly the regime E1 needs it recorded.
//	ENOMEM   the kernel could not allocate an skb. Transient, same shape.
//	EAGAIN / EWOULDBLOCK  a non-blocking socket that the runtime did not park on
//	         (they are the same value on Linux; both are listed because the pair
//	         is not guaranteed equal everywhere and the cost of listing both is
//	         nil).
//
// Everything else is path-down. That includes EINVAL, which is listed in the
// path-down set NOT because it is a network condition but because it is a
// programming/address fault that retrying cannot fix -- retrying it would spin
// forever on a frame that can never leave.
func classifySend(err error) sendResult {
	if err == nil {
		return sendOK
	}
	if errors.Is(err, syscall.ENOBUFS) ||
		errors.Is(err, syscall.ENOMEM) ||
		errors.Is(err, syscall.EAGAIN) ||
		errors.Is(err, syscall.EWOULDBLOCK) {
		return sendBackpressure
	}
	return sendPathDown
}

// newPullLinkSock builds a link over the seam. It is the real constructor;
// NewPullLink is the *net.UDPConn wrapper the daemon uses.
func newPullLinkSock(idx int, ifname string, sock linkSocket, dst *net.UDPAddr) *PullLink {
	l := &PullLink{idx: idx, ifname: ifname, sock: sock, dst: dst, minOkNs: -1}
	atomic.StoreInt32(&l.alive, 1)
	atomic.StoreInt64(&l.lastRxMs, time.Now().UnixMilli())
	return l
}

// NewPullLink builds a link over a real bound socket. A nil conn is stored as a
// nil INTERFACE, not as a typed-nil: l.sock == nil must be true for a link with
// no socket, and it is what disabled() tests.
func NewPullLink(idx int, ifname string, conn *net.UDPConn, dst *net.UDPAddr) *PullLink {
	var s linkSocket
	if conn != nil {
		s = conn
	}
	return newPullLinkSock(idx, ifname, s, dst)
}

func (l *PullLink) Ifname() string { return l.ifname }

func (l *PullLink) Idx() int { return l.idx }

// disabled reports why this link can NEVER send, or "" if it can. Both reasons
// are structural and neither can change at run time, so the check is made once
// at the top of Drive (the link does not draw at all) and once more in send (the
// invariant: a truncated pathID is never put on the wire, and a nil socket is
// never dereferenced).
func (l *PullLink) disabled() string {
	switch {
	case l.sock == nil:
		return "no socket"
	case l.idx >= MaxLinks:
		return "link index is at or past the wire's one-byte pathID ceiling"
	}
	return ""
}

// MarkRx records that the far end was heard on this link.
func (l *PullLink) MarkRx() { atomic.StoreInt64(&l.lastRxMs, time.Now().UnixMilli()) }

// RxAge is how long since anything arrived on this link.
func (l *PullLink) RxAge(now time.Time) time.Duration {
	return time.Duration(now.UnixMilli()-atomic.LoadInt64(&l.lastRxMs)) * time.Millisecond
}

func (l *PullLink) SetAlive(v bool) {
	var x int32
	if v {
		x = 1
	}
	atomic.StoreInt32(&l.alive, x)
}

func (l *PullLink) Alive() bool { return atomic.LoadInt32(&l.alive) == 1 }

func (l *PullLink) Sent() uint64 { return atomic.LoadUint64(&l.sent) }

func (l *PullLink) Bytes() uint64 { return atomic.LoadUint64(&l.bytes) }

func (l *PullLink) Errs() uint64 { return atomic.LoadUint64(&l.errs) }

// Bpress is the number of writes REFUSED for lack of room (backpressure class).
// Paired with BlockedMs it says whether the refusals were brief or sustained.
func (l *PullLink) Bpress() uint64 { return atomic.LoadUint64(&l.bpress) }

// Defers is how many times this link deferred to a better-ranked one, and
// DeferMs is the wall time it spent doing so. Both are exactly 0 for the whole
// life of a `max` process: nothing writes them when no gate is installed.
func (l *PullLink) Defers() uint64 { return atomic.LoadUint64(&l.defers) }

// DeferMs is the deferral time in milliseconds, kept out of BlockedMs on
// purpose -- see the deferNs field comment.
func (l *PullLink) DeferMs() int64 {
	return atomic.LoadInt64(&l.deferNs) / int64(time.Millisecond)
}

// setGateClosed publishes this link's gate state and reports whether it CHANGED.
// Edge, not level: the caller fires a rank event only on a transition, so a link
// that stays refused for a minute produces one event and not one per retry.
func (l *PullLink) setGateClosed(v bool) bool {
	var x int32
	if v {
		x = 1
	}
	return atomic.SwapInt32(&l.gateClosed, x) != x
}

// GateClosed reports whether this link has published that it would not take a
// frame right now.
func (l *PullLink) GateClosed() bool { return atomic.LoadInt32(&l.gateClosed) == 1 }

// Eligible is what the rank gate means by "a link that could carry this frame":
// structurally able to send at all, alive, and not currently gate-closed. It is
// read from ANOTHER link's goroutine, so every term is an atomic or an immutable
// field -- l.sock and l.idx are written once at construction.
//
// A link that is not eligible neither draws nor BLOCKS anyone: a dead or refused
// better-ranked source must not pin a worse one, which is the entire spill rule.
func (l *PullLink) Eligible() bool {
	return l != nil && l.disabled() == "" && l.Alive() && !l.GateClosed()
}

// ---------------------------------------------------------------------------
// THE THREE SEND-SIDE COUNTERS. Each one means exactly one thing, and the
// previous revision's single counter did not: it charged EVERY write, successful
// ones included, while its own comment said it was the time the link was "unable
// to place a frame". A successful sendto that returns immediately is neither
// unable nor blocked, so a mid-limited link at a few thousand pps with a ~10us
// sendto charged tens of ms per wall second -- a throughput-proportional FLOOR
// that reads exactly like mild edge blocking. E1 would have read a confident
// wrong answer off it. Splitting them is the fix; each name now matches its
// contents and no reader has to remember a caveat.
// ---------------------------------------------------------------------------

// BlockedMs is the cumulative wall time this link was UNABLE TO PLACE A FRAME,
// and nothing else. It is the sum of two things and only two: the time spent
// inside writes that RETURNED a backpressure errno, and the time spent waiting
// after such a refusal before retrying. It is exactly zero on a link whose
// writes all succeed. It does NOT include time inside a successful write, so it
// carries no per-write syscall floor and does not scale with throughput.
//
// Time spent inside a write that failed path-down is charged to no counter at
// all; Errs counts those events, and their duration is not a bottleneck signal.
//
// It is a diagnostic; nothing in the datapath reads it.
func (l *PullLink) BlockedMs() int64 {
	return atomic.LoadInt64(&l.blockedNs) / int64(time.Millisecond)
}

// WriteNs is the cumulative wall time inside writes that SUCCEEDED. It includes
// the unavoidable per-write syscall cost AND any time the Go netpoller parked
// the writer on EAGAIN before the write completed. Those two are not separable
// without a second clock inside the runtime, which is why this counter is
// reported next to a MEASURED floor rather than pretending to be park time.
// Divide by Sent() for the mean cost of a successful write.
func (l *PullLink) WriteNs() int64 { return atomic.LoadInt64(&l.okWriteNs) }

// WriteFloorNs is the SMALLEST successful write this link has ever seen: the
// per-write syscall floor, measured on this box and this socket rather than
// assumed. -1 until the first successful write.
//
// HOW E1 READS THE THREE TOGETHER (this is the whole edge-vs-mid discriminator,
// and no single counter is it):
//
//	Bpress > 0                    the device queue is REFUSING writes. Edge
//	                              backpressure, ENOBUFS regime. BlockedMs is how
//	                              long, in wall time, this link could not place.
//	Bpress == 0 and
//	WriteNs/Sent >> WriteFloorNs  writes succeed but are being HELD UP inside the
//	                              call: edge backpressure, netpoller-park regime.
//	                              The comparison is against this link's own
//	                              measured floor, so it needs no constant.
//	Bpress == 0 and
//	WriteNs/Sent ~= WriteFloorNs  the writer is never held up. NOT locally edge
//	                              limited. If RTT is climbing at the same time,
//	                              that is the MID regime -- and it reads ~0 on
//	                              BlockedMs, which is what makes BlockedMs usable
//	                              as a discriminator at all.
func (l *PullLink) WriteFloorNs() int64 { return atomic.LoadInt64(&l.minOkNs) }

// foldMinOk keeps the running minimum successful-write duration. CAS rather than
// load-store because a test may drive send() from more than one goroutine even
// though the daemon runs exactly one Drive per link.
func (l *PullLink) foldMinOk(d int64) {
	for {
		cur := atomic.LoadInt64(&l.minOkNs)
		if cur >= 0 && cur <= d {
			return
		}
		if atomic.CompareAndSwapInt64(&l.minOkNs, cur, d) {
			return
		}
	}
}

// SndBuf reports SO_SNDBUF for this link's socket, or -1 if it cannot be read
// (including a link with no socket, which is how the N-genericity tests build a
// core, and a fake socket in the send tests). Logged at start so E1 can measure
// how much local queue "the socket accepted it" actually permits, and used to
// derive the pool's byte limb (S3).
func (l *PullLink) SndBuf() int {
	if l.sock == nil {
		return -1
	}
	rc, err := l.sock.SyscallConn()
	if err != nil || rc == nil {
		return -1
	}
	v := -1
	rc.Control(func(fd uintptr) {
		if x, e := syscall.GetsockoptInt(int(fd), syscall.SOL_SOCKET, syscall.SO_SNDBUF); e == nil {
			v = x
		}
	})
	return v
}

// send packs and writes one frame. The write is the ONLY thing that decides
// whether this link could send: a device-bound UDP socket either parks this
// goroutine until the device drains, or refuses with a backpressure errno when
// the queue that filled is the DEVICE queue rather than the socket buffer. Both
// are the real drain the pivot is built on; see classifySend.
//
// fseq is this link's own contiguous frame sub-sequence, so the peer's per-path
// loss meter has a gap-free series to measure against; the pull core sends no
// parity, so fseq is measurement-only here.
//
// NOTE ON fseq UNDER BACKPRESSURE: fseq is consumed only when the frame is
// actually written. A refused frame does not burn a sub-sequence number, because
// the peer's loss meter counts a gap in fseq as a LOSS -- burning one here would
// manufacture per-path loss out of local backpressure and feed the peer a
// fabricated number. Asserted, not asserted-by-inspection:
// TestPullSendRefusalDoesNotBurnFseq.
//
// The disabled() guard is an INVARIANT, not a policy: Drive already refuses to
// run such a link. It is here so no caller can make this link dereference a nil
// socket or emit byte(idx) truncated mod 256 into the pathID field, which would
// merge two links' OWD, loss and fseq series at the peer.
func (l *PullLink) send(fr *PullFrame, out []byte) sendResult {
	if l.disabled() != "" {
		atomic.AddUint64(&l.errs, 1)
		return sendPathDown
	}
	m := Pack(out, FlagData, byte(l.idx), fr.seq, nowMS(), l.fseq, fr.payload)
	t0 := time.Now()
	n, err := l.sock.WriteToUDP(out[:m], l.dst)
	d := int64(time.Since(t0))
	switch classifySend(err) {
	case sendBackpressure:
		atomic.AddUint64(&l.bpress, 1)
		atomic.AddInt64(&l.blockedNs, d)
		return sendBackpressure
	case sendPathDown:
		atomic.AddUint64(&l.errs, 1)
		return sendPathDown
	}
	l.fseq++
	atomic.AddUint64(&l.sent, 1)
	atomic.AddUint64(&l.bytes, uint64(n))
	atomic.AddInt64(&l.okWriteNs, d)
	l.foldMinOk(d)
	return sendOK
}

// txBackoff is the operator override for what a link does after a backpressure
// refusal. Default 0 means "no invented duration": the link parks on
// PullFIFO.WaitWork until DRAIN EVIDENCE appears -- not until the pool changes;
// see the DRAIN WAKE SET block at the top of the file for the difference and why
// it is the whole of the round-4 fix. A nonzero value substitutes a real sleep of
// that length. Set once at start from AGG_PULL_TXBACKOFF_US and logged; never
// written after Start.
var txBackoff time.Duration

// backoff is what a link does after its socket REFUSED a frame, and the wait is
// CHARGED to BlockedMs -- being refused and waiting to retry are both time this
// link could not place work, and they are the two halves of what that counter
// means.
//
// The default waits on a DRAIN EVENT rather than a duration: see WaitWork, and
// see the DRAIN WAKE SET block at the top of this file for the two revisions
// whose spin-boundedness claims were false, and the tests that now decide it.
func (l *PullLink) backoff(f *PullFIFO) {
	t0 := time.Now()
	if txBackoff > 0 {
		time.Sleep(txBackoff)
	} else {
		f.WaitWork()
	}
	atomic.AddInt64(&l.blockedNs, int64(time.Since(t0)))
}

// Drive is the PULL DRAW LOOP for ONE link. N of these run concurrently and that
// is the only place N appears in the datapath.
//
// It is the port of PIECE 1 of reserved_composite.py SimD.run: the head frame is
// the unit, a link draws only while it can send, the pool is popped only when the
// frame is taken, and a link that cannot place stops drawing (the sim's `break`).
// The sim's room(i) proxy `_local_ms(i) < target_ms` is replaced by the socket
// itself -- see the port map at the top of this file.
//
// The liveness gate is not a datapath decision and not a new constant: a link the
// far end has stopped answering on must not draw into a black hole (its socket
// would keep accepting writes), and PingIval is already the cadence at which
// liveness can change at all.
func (l *PullLink) Drive(f *PullFIFO) {
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
			// U17a: a dead link publishes its gate CLOSED so it stops pinning
			// worse-ranked links under AGG_SCHED=speed. Under `max` l.gate is
			// nil and this whole branch is skipped, so the loop is U7's.
			if l.gate != nil && l.setGateClosed(true) {
				f.RankChanged()
			}
			if f.Closed() {
				return
			}
			time.Sleep(PingIval)
			continue
		}
		// E2b: the CAP half of room(). OFF unless AGG_PULL_CAP=on, in which case
		// this is a nil-receiver call returning true (cap.go). Consulted BEFORE
		// the draw because that is where the oracle consults room()
		// (reserved_composite.py @"cand = [i for i in range(s.N) if room(i)]") -- a
		// link with no room takes no frame,
		// rather than taking one and returning it.
		//
		// The retry cadence is PingIval and it is NOT a new constant: the cap's
		// inputs change only when a server echo is folded, echoes are replies to
		// this daemon's own pings, and pings leave at PingIval
		// (pullrun.go's control loop). Polling faster than the meter updates
		// observes nothing new. That is the same argument the liveness gate above
		// already makes for the same constant.
		//
		// The wait is deliberately NOT charged to BlockedMs. That counter means
		// "the device would not take a frame" and is E1's edge discriminator
		// (pull.go, WriteFloorNs); a cap refusal is this daemon's own policy
		// declining to offer one, and folding the two together would make a
		// latched cap read exactly like edge backpressure in the measurement E1
		// depends on. Cap refusals are counted separately, in CapStats.Refusals.
		if !l.cap.Admit(l.idx, time.Now()) {
			// U17a: a latched cap is a CLOSED gate, and a better-ranked link
			// whose cap has latched must stop pinning the worse ones -- that is
			// the mid-bottleneck half of spill, where the socket never refuses
			// because the queue is downstream.
			if l.gate != nil && l.setGateClosed(true) {
				f.RankChanged()
			}
			if f.Closed() {
				return
			}
			time.Sleep(PingIval)
			continue
		}
		// ---- U17a: the RANK gate. AGG_SCHED=speed only. -------------------
		//
		// Consulted HERE, after liveness and the cap and before the draw, for
		// the same reason the cap is: the oracle consults room() before taking
		// the head frame (reserved_composite.py @"cand = [i for i in range(s.N)
		// if room(i)]"), and a link that should not carry this frame takes none
		// rather than taking one and returning it.
		//
		// What it does NOT do is decide anything about the FRAME. There is no
		// per-frame classification anywhere in this daemon -- it carries one
		// opaque encrypted WG flow and must not look inside it (design sec 4.3c).
		// The gate is per-LINK and level-triggered off statistics the ping/echo
		// stream feeds whether or not this link ever draws.
		//
		// With AGG_SCHED=max, l.gate is nil: no call, no atomic, no branch taken.
		if g := l.gate; g != nil {
			// This link is alive and admitted, so its gate is OPEN. Publish that
			// (it may have been closed by a refusal that has since been retried)
			// and deliberately DISCARD the transition: a gate OPENING can only
			// make a deferring link defer again, so firing a rank event here
			// would let two links flapping open/closed wake each other at CPU
			// speed -- the round-4 spin with a different trigger. Only CLOSES
			// are events.
			//
			// HONEST WINDOW, recorded not fixed: a permanently refusing link is
			// released by the tick, clears its gate HERE, and only re-closes it
			// after the next write is refused. For that one write attempt a
			// worse-ranked link sees it as open and defers. It resolves on the
			// refusal (which fires RankChanged), not on the following tick, so
			// the cost is one write attempt and not 100 ms -- but it is a real
			// window and it is not closed by anything below.
			l.setGateClosed(false)
			if !g.MayDraw(l.idx) {
				t0 := time.Now()
				atomic.AddUint64(&l.defers, 1)
				if f.Closed() {
					return
				}
				f.WaitRank()
				atomic.AddInt64(&l.deferNs, int64(time.Since(t0)))
				if f.Closed() {
					return
				}
				continue
			}
		}
		// Closed is consulted only off the hot path (Draw already reports
		// !ok on close), so the shared pool lock is taken once per frame.
		fr, ok := f.Draw()
		if !ok {
			if f.Closed() {
				return
			}
			continue
		}
		switch l.send(fr, out) {
		case sendOK:
			// The one direct piece of evidence in the system that a device is
			// draining. Hand it to any link parked after a refusal; costs one
			// atomic load when nobody is parked, which is the normal case.
			f.Progress()
		case sendBackpressure:
			// room(i) came back FALSE. The oracle's response is to place
			// nothing and let another candidate take the head frame, so the
			// frame goes back to the pool rather than being dropped here: any
			// link may still take it, and the pool bound can see it again.
			// This link then waits for DRAIN EVIDENCE before drawing again --
			// charged to BlockedMs, because it is time this link could not
			// place work. The Return on the line above releases a DRAWER but
			// deliberately does not release a parked refuser, this link
			// included: see the DRAIN WAKE SET block at the top of the file.
			//
			// U17a: the refusal is also THE gate-close event. Publish it BEFORE
			// parking, so a worse-ranked link deferring to this one is released
			// by the same refusal that made it eligible. Publishing after the
			// park would defer the spill by a whole control tick, which is the
			// difference between a call hiccup nobody hears and one they do.
			if l.gate != nil && l.setGateClosed(true) {
				f.RankChanged()
			}
			f.Return(fr, time.Now())
			l.backoff(f)
			if f.Closed() {
				return
			}
		case sendPathDown:
			// Nothing retrying can fix. The frame is consumed and counted in
			// errs; the liveness gate is what removes the link from the draw
			// set, and it is level-triggered off RxAge, not off this error.
			//
			// HONEST GAP, recorded not fixed: between the first path-down error
			// and DeadIval expiring, this link keeps drawing at full speed and
			// destroying every frame it draws, which can starve the healthy
			// links of work for up to DeadIval. Returning the frame instead
			// would livelock on a frame that can never leave, so neither
			// behaviour is right; the fix is a send-side liveness signal and
			// nobody owns one yet.
		}
	}
}

// PullCore is the shared pool plus the set of links drawing from it. Links is
// the ONLY carrier of N; nothing else in the core knows how many there are.
type PullCore struct {
	FIFO  *PullFIFO
	Links []*PullLink
}

// NewPullCore builds a core over len(ifnames) links. ifnames and conns must be
// the same length; the caller has already bound each socket to its device.
//
// It does NOT enforce the wire's pathID ceiling -- pullrun.go refuses to start
// past it, which is the operator-facing check, and Drive/send enforce it per
// link. Construction stays total so the N-genericity tests can build any N.
func NewPullCore(ifnames []string, conns []*net.UDPConn, dst *net.UDPAddr) *PullCore {
	c := &PullCore{FIFO: NewPullFIFO()}
	for i := range ifnames {
		c.Links = append(c.Links, NewPullLink(i, ifnames[i], conns[i], dst))
	}
	return c
}

func (c *PullCore) N() int { return len(c.Links) }

// SetCap installs the E2b delivered-rate gate on every link. m may be nil, which
// is the shipped default and leaves the draw loop exactly as U7 wrote it.
// (Named m, not cap: cap is a Go builtin and a parameter of that name shadows
// it for the whole function body.)
//
// Call BEFORE Start: the field is read without synchronisation on the draw path,
// and it is written once here. Installing a cap on a running core would be a
// data race and there is no reason to -- enablement is a start-time decision
// (E1 sets it, cap.go).
// Test: TestPullDriveConsultsTheCapBeforeDrawing.
func (c *PullCore) SetCap(m *Cap) {
	for i := range c.Links {
		c.Links[i].cap = m
	}
}

// SetSched installs the U17a scheduler policy's DRAW-ORDER half on every link.
// It is the datapath's consumer of AGG_SCHED.
//
// RankDrainOrder (`max`) installs NOTHING: every link's gate stays nil, Drive
// runs U7's loop verbatim, and no atomic that this unit added is ever written.
// That is the property that makes the change safe to land unbuilt -- the mode
// the box runs today cannot be regressed by a gate that does not exist in it.
//
// RankDeadlineHit (`speed`) installs one shared rankGate over c.Links. It holds
// the SLICE, not a copy of the links, so it sees each link's live gate state;
// the slice itself is never mutated after NewPullCore.
//
// A nil ranker degrades `speed` to `max`'s draw order rather than refusing --
// and that is stated, not silent: with no statistics nothing is strictly better
// than anything, so every eligible link draws. It is the same graceful floor the
// daemon lands on when the peer's echo surface is dead, which is the ONE way
// `speed`'s draw order can silently equal `max`'s. Delivery still differs
// unconditionally, so the modes are never wholly identical.
//
// Call BEFORE Start, for the same reason SetCap says so: the field is read
// without synchronisation on the draw path and written once here.
func (c *PullCore) SetSched(p SchedPolicy, rk *Ranker) {
	if p.Rank != RankDeadlineHit || rk == nil {
		for i := range c.Links {
			c.Links[i].gate = nil
		}
		return
	}
	g := &rankGate{rk: rk, links: c.Links}
	for i := range c.Links {
		c.Links[i].gate = g
	}
}

// Start launches one draw goroutine per link.
func (c *PullCore) Start() {
	for i := range c.Links {
		go c.Links[i].Drive(c.FIFO)
	}
}

// Offer hands one WG datagram to the pool. This is the entire send-side API: the
// caller chooses no path, computes no ETA and consults no estimate.
func (c *PullCore) Offer(payload []byte, now time.Time) uint32 {
	return c.FIFO.Enqueue(payload, now)
}
