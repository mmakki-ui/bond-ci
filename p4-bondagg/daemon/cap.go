package main

// =============================================================================
// U15a / E2b -- THE ONE-SIDED DELIVERED-RATE CAP.  FLAG-GATED, OFF BY DEFAULT.
//
// This file is ADDITIVE. It does not touch the EIF push stack (eif.go, estr.go,
// qtrack2.go, fec.go, frame.go, ring.go, paths.go, util*.go), and it leaves
// runClient/runServer alone.
//
// WITH THE FLAG OFF, which is the shipped state, the whole of E2b is: a nil *Cap,
// one nil-receiver Admit per draw that returns true, one nil-receiver MarkPing
// per ping, and a FlagEcho case in the receive switch that does nothing. The
// tested claim is narrower than "unchanged" and is exactly this: the pool still
// drains through every link at N in {1,2,3} with the cap off
// (TestPullDriveIsUnchangedWithTheCapOff). Object-code identity with U7 is NOT
// claimed and is not tested -- the nil-check is real, it is just never false.
//
// WHAT IT IS FOR, and why it is off
//   The cap exists ONLY for a hidden MID-network bottleneck (carrier
//   bufferbloat): a regime where the local socket says everything is fine while
//   the far end delivers less than we send. That regime is UNCONFIRMED on this
//   hardware. G1/E1 is the measurement that confirms or refutes it
//   (ROADMAP.md @"| G1 | **E1 hardware probe**",
//   p5-execution-handover.md @"HARDWARE REALITY PROBE (edge-vs-mid)"). So E2b is
//   BUILT and DISABLED: p5-execution-handover.md
//   @"E2b/E2c/E3/E4/E5/E6 built (cap+lightning *enablement* set by E1)"
//   sequences E2b as built with its ENABLEMENT set by E1, and ROADMAP.md
//   @"| U15a | E2b **CAP**" records U15a as "built flag-gated; E1 sets
//   enablement".
//
// THE FLAG IS NOT THE ONLY GATE, AND THAT IS DELIBERATE.
//   Every threshold this cap needs is a number nobody has derived -- but they
//   are un-derived for TWO DIFFERENT REASONS, and an earlier draft of this
//   comment collapsed them into one by claiming all five carry
//   masterpiece_dp.py's "(*)" marking. They do not. Corrected, checked against
//   the file:
//     - The legend (masterpiece_dp.py
//       @"the (*) rows are set for real on the hardware") reads "the (*) rows
//       are set for
//       real on the hardware edge-vs-mid box test". Exactly TWO of this cap's
//       five numbers carry it: CAP_TRIP (:96) and CAP_CLEAR (:97). The only
//       other (*) rows in that block, MIRROR_SPARE_MS (:107) and
//       MIRROR_RISK_FRAC (:108), belong to the opportunistic mirror ADR-002
//       dropped and are nothing to do with the cap.
//     - TARGET_MS (:93), CAP_DET_W (:104) and MINRATE (:106) carry NO marking.
//       The legend calls an unmarked row a "validated model value" -- validated
//       IN THE MODEL. ADR-004's still-open condition is that neither simulator
//       has ever been compared to a real router, so a validated model value is
//       still a number with nothing from hardware behind it. That is a weaker
//       claim than the "(*)" one, and it is the claim that actually applies to
//       three of the five.
//   Either way, a model value typed into a default is an invented constant with
//   a citation stapled to it. So this file contains NO threshold at all.
//   AGG_PULL_CAP=on with any of them missing is a FATAL config error that names
//   E1. The
//   consequence is structural rather than documentary: the cap CANNOT be
//   switched on before the experiment that produces its numbers has run.
//   See CapConfigFromEnv and TestCapConfigRequiresEveryUnderivedNumber.
//
// NO ESTIMATOR REAPPEARS HERE.
//   Everything below is a DIFFERENCE OF COUNTERS the two ends already keep. The
//   client's own cumulative wire bytes per link (PullLink.Bytes, incremented
//   from the write's return value) and the server's cumulative received wire
//   bytes per link (server/echo.go LinkStats). There is no rate PREDICTION, no
//   ETA, no Smith term, no argmin, and no per-path model. The delivered rate is
//   a measured quotient of two observed increments, used as a DIVISOR to convert
//   an observed byte backlog into milliseconds -- it never forecasts anything.
//
// =============================================================================
// THE WIRE, AND THE THREE SEMANTICS THIS CONSUMER MUST HONOUR
// (p4-bondagg/server/echo.go is the contract; read it before changing anything
// here. Each of its three stated hazards has a named test below.)
//
//   1. COUNTER REGRESSION MEANS THE SERVER RESTARTED. echo.go:29-39: the
//      counters are cumulative and monotone FOR THE PROCESS LIFETIME, and a
//      restart zeroes them. Differencing across the restart computes an inflight
//      of about sent_cum and latches the cap permanently shut. The contract is
//      explicit that the fix is a RE-BASELINE and NOT a clamp at zero, because a
//      clamp hides the restart and holds a stale, too-large inflight.
//      Here: foldRecord detects rx < lastRx, resets the link's meter to a fresh
//      baseline, drops the interval, and CLEARS the latch (a restart is not
//      evidence of a downstream deficit).
//      Test: TestCapServerRestartRebaselinesAndDoesNotLatchShut.
//
//   2. srvMS IS uint32, WRAPS EVERY ~49.7 DAYS, AND IS WALL CLOCK NOT MONOTONIC
//      (echo.go:83-99). So the interval is differenced as uint32 and read as
//      int32 -- the same wrap-safe idiom ring.go uses for seq -- and a
//      non-positive interval (an NTP step backwards, or two snapshots inside one
//      millisecond) is DROPPED rather than turned into a rate.
//      DROPPED means exactly this and no more: the baselines re-anchor on the
//      new values, the delivered rate is discarded (so Admit fails this link
//      open through the deadlock break until a real interval exists), and the
//      LATCH, the queue accumulator and the detector window are left untouched.
//      A broken server clock is not evidence that a downstream deficit ended.
//      Tests: TestCapSrvMSWrapDoesNotZeroTheDeliveredRate,
//      TestCapSrvMSBackwardsStepIsDroppedNotRated,
//      TestCapBadIntervalIsNotALatchExit.
//
//   3. AN UNKNOWN linkID IS IGNORED, AND TRUNCATION IS INVISIBLE (echo.go:133-153).
//      A record for a link this client never sent on is dropped without error --
//      it can come from a stale peer, a restart or a forged frame. Above the
//      server's maxEchoRecs seen links the snapshot keeps the LOWEST ids with NO
//      truncation bit on the wire, so a client cannot tell "never seen" from
//      "truncated away". This consumer therefore cannot detect truncation
//      either. What it does instead is the only thing available: a link whose
//      meter has gone STALE fails OPEN (see ECHO LOSS below), so a truncated-away
//      link degrades to plain pull rather than to a shut cap.
//      Tests: TestCapUnknownLinkRecordIsIgnored, TestCapEchoLossFailsOpen.
//
// =============================================================================
// LAG ALIGNMENT -- THE LOAD-BEARING PART, AND THE #1 IMPLEMENTATION RISK
//
// The failure it prevents (p5-execution-handover.md
// @"difference **lag-aligned** counters", echo.go:76-81): the
// UN-ALIGNED difference sent_cum(now) - rxBytes latches the cap permanently
// shut. Written out, because "lag-aligned" on its own is a slogan:
//
//   An echo the client holds at time `now` was snapshotted by the server at
//   about now - RTT. Its rxBytes therefore accounts for bytes the client sent up
//   to about now - RTT. Differencing it against sent_cum(NOW) charges a whole
//   round trip of the client's own sending to "inflight". Under sustained load
//   that term is rate*RTT and it NEVER shrinks, so inflight/rate >= RTT for
//   ever. Against any target smaller than the RTT the gate is closed on every
//   evaluation, on a perfectly healthy path, permanently.
//
// The fix needs no clock sync at all, and that is the point of echoing the
// txstamp VERBATIM (echo.go:76). The client stamps each ping with its OWN clock,
// records its OWN sent counter at that instant, and the server hands that same
// stamp back. So when an echo carrying txstamp T arrives, the client can look up
// what it had sent AT T -- a value in its own clock, never compared against the
// server's. sentAt(T) - rxBytes is then a difference of two counters taken at
// the SAME point in the byte stream. srvMS is used for the rate DENOMINATOR only
// (echo.go:83-87), where only the interval matters, so a clock offset cancels
// there too.
//
// HOW THE ALIGNMENT IS TESTED, and this is the part that matters:
//   TestCapLagAlignedMeterDoesNotLatchUnderCleanSustainedLoad drives a synthetic
//   clean path -- constant offered rate, everything delivered, echoes lagged by a
//   whole RTT -- through the REAL fold path, and asserts the cap never closes.
//   The SAME sequence is then run through unalignedInflight(), the naive
//   difference, in TestCapUnalignedDifferenceWouldLatchOnTheSameCleanTrace, which
//   asserts that it DOES exceed the budget. Two tests, one trace: the second is
//   what makes the first mean something. An alignment test that only shows the
//   aligned path staying open proves nothing -- a meter that always returns zero
//   passes it.
//   unalignedInflight lives in cap_test.go, not here: it is scaffolding for the
//   second test and nothing in the datapath calls it. It exists so the failure
//   being prevented is EXECUTED rather than described.
//
// WHAT THE ALIGNED DIFFERENCE ACTUALLY MEASURES -- TWO REGIMES, AND THIS FILE
// PREVIOUSLY STATED BOTH AS IF THEY WERE ONE.
//   The earlier text argued (a) that the ping is a FIFO BYTE MARKER, so a full
//   bufferbloat buffer shows up as ping LATENCY and not as a counter deficit,
//   and then (b) that the per-interval increment of the same difference IS "the
//   growth of the hidden downstream queue". Those two cannot both hold. If (a)
//   is true then by the time the server snapshots at ping arrival
//   (server/main.go:299-305) every byte sent before that ping has already
//   arrived or been dropped, so the interval deficit contains NO queued bytes at
//   all -- it is exactly the bytes LOST in that interval. Statement (b) requires
//   the opposite: that data is still standing in the bottleneck buffer when the
//   ping is snapshotted.
//   Both are physically possible; which one holds is a property of the path, not
//   of this code, so the regimes are named instead of picked:
//
//     REGIME A -- the ping shares ONE FIFO with the data. It is a strict byte
//       marker. The interval deficit is LOSS, not queue. queueBytes is then a
//       loss accumulator, farMS = lost_bytes / delivered_rate is not a drain
//       time, and a steady-loss path with NO queue anywhere still latches and
//       still throttles. That is the open question recorded below and in the
//       unit result; it is a real behaviour of this design, not a bug to be
//       argued away.
//
//     REGIME B -- the ping is NOT strictly behind the data: a separate flow
//       queue (fq_codel / WRR hashing the ping into its own bucket), a
//       different class, or any non-FIFO discipline at the bottleneck. The ping
//       overtakes the standing backlog, so bytes sent before it are still
//       queued when the server snapshots, and the interval deficit IS the queue
//       growth over that interval. This is the regime the BOUND is built for.
//
//   THE BOUND ASSUMES REGIME B AND DEGRADES INTO A LOSS METER UNDER REGIME A.
//   Under A the detector still identifies the mid signature correctly (delivered
//   < sent with the local socket uncongested); it is the BOUND's units that stop
//   meaning milliseconds of queue.
//   WHICH REGIME HOLDS ON THE TARGET PATH IS OPEN AND IS E1's TO ANSWER -- it is
//   the same question as "does the ping share the bottleneck queue with the
//   data", which is G1/E1 and Mo's measurement. Nothing here decides it.
//   Accumulating only FROM THE LATCH bounds the drift of either reading by the
//   latched duration instead of by uptime, which is why the accumulator resets
//   on clear. Recorded as substitution S8 below.
//
// =============================================================================
// THE TWO HALVES (masterpiece_dp.py @"Two parts -- a DETECTOR and a BOUND"
// states the same split)
//
// DETECTOR -- sticky, asymmetric, CAP_CLEAR hysteresis. Over a window it
//   compares delivered bytes against sent bytes on the SAME link:
//     LATCH  when  delivered < Trip * sent  AND the local socket was UNCONGESTED
//            over that window. The conjunction is the pure MID signature: "the
//            socket took everything and the far end delivered less". At the EDGE
//            a delivered<sent deficit arrives WITH a congested local socket, so
//            the AND excludes it and the cap is dormant BY CONSTRUCTION rather
//            than by tuning.
//     CLEAR  when  delivered > Clear * sent  (the far end is visibly outpacing
//            us, so the bottleneck lifted) OR the local socket congested (the
//            regime genuinely returned to edge).
//     HOLD   otherwise. This asymmetry is the whole design: a well-controlled
//            mid path settles at delivered == sent (ratio 1.0), which is neither
//            a latch nor a clear, so it correctly STAYS latched instead of
//            flapping the way a symmetric band would.
//   LOCAL CONGESTION IS OBSERVED, NOT ESTIMATED: it is the change in
//   PullLink.Bpress() over the window -- writes the socket actually refused.
//   That is the same ENOBUFS signal E1 reads as the edge discriminator
//   (pull.go, WriteFloorNs).
//   Tests: TestCapDetectorLatchesOnMidDeficit, TestCapDetectorDoesNotLatchAtTheEdge,
//   TestCapClearHysteresisHoldsAtUnityRatio, TestCapClearReleasesWhenFarEndOutpaces,
//   TestCapLocalCongestionReleasesTheLatch.
//
//   THE LATCH BIT IS NEAR-PERMANENT ON A MID PATH, BY DESIGN, AND THIS FILE USED
//   NOT TO SAY SO. Read the three arms together:
//     - CLEAR by ratio needs delivered > Clear * sent over a window. With the
//       model's Clear = 1.5 that means the far end must deliver 50% MORE than
//       was sent into the window. Only a DRAIN TRANSIENT produces that -- a
//       standing backlog emptying while the sender is throttled. A healthy,
//       steady mid path never does; it sits at ratio ~= 1.0, which is the HOLD
//       arm.
//     - Once the cap throttles, the link's own sent volume falls, and a window
//       whose sent rate drops below MinRateKbps takes the "too little traffic to
//       judge" arm in evaluate() -- which HOLDS the latch and explicitly does not
//       move it in either direction. So throttling produces exactly the windows
//       that refuse to re-judge the latch.
//     THE BOUND MODULATES; THE LATCH DOES NOT CLEAR. What varies once latched is
//     admission, farMS vs TargetMS, cycling as queueBytes accumulates and drains.
//     The latch bit itself stays set.
//   The exits that DO exist. This list is checked against the code, and the
//   check is mechanical rather than a promise: the latch-clearing assignment
//   appears EXACTLY where this list says it does and in no other place, and the
//   zero-rate limb is the one admission exit that leaves the bit set.
//     1. a CLEAR-ratio window (delivered > Clear * sent) -- evaluate's ratio arm
//     2. LOCAL CONGESTION returning: the regime is edge again. Both the ratio
//        arm and the too-little-traffic arm in evaluate check it
//     3. a SERVER RESTART, i.e. a counter regression -- rebase clears it,
//        together with the first reading ever, where there is no latch yet
//     4. the DeadIval STALENESS fail-open in Admit
//     5. the ZERO-RATE DEADLOCK BREAK in Admit -- which admits WITHOUT clearing
//        the latch, so it is an admission exit and not a latch exit
//   Every one of them is an event, not a gradual recovery.
//   A NON-POSITIVE srvMS INTERVAL IS NOT ON THIS LIST AND USED TO BE. Round 2
//   routed it through rebase(), so an NTP step backwards on the server cleared a
//   mid-deficit latch -- a fourth, unlisted exit with a different trigger, in
//   the same block that declared the list complete. It is now skipInterval,
//   which re-anchors the baselines and drops the rate and touches neither the
//   latch nor the queue accumulator.
//   Test: TestCapBadIntervalIsNotALatchExit, TestCapLatchExitsAreTheDocumentedSet.
//
// BOUND -- only while latched. farMS = queueBytes / deliveredBytesPerMs, and the
//   gate is farMS < TargetMS. queueBytes is the accumulated per-interval deficit
//   described above, reset when the latch clears. Unlatched, Admit returns true
//   without consulting anything: the cap is dormant and plain pull rules.
//   ITS UNITS ARE REGIME-DEPENDENT: farMS is a drain time only under REGIME B.
//   Under REGIME A it is lost_bytes/delivered_rate, which is not a time the queue
//   takes to drain, and a steady-loss path with no queue anywhere then throttles.
//   Open, and E1's to settle -- see the two regimes above.
//   Tests: TestCapAdmitIsDormantWhileUnlatched, TestCapBoundClosesWhenQueueTimeExceedsTarget,
//   TestCapBoundReopensAsTheQueueDrains.
//
// =============================================================================
// ECHO LOSS, AND WHY IT FAILS OPEN
//   A lost echo costs nothing by construction (echo.go:40-46): the counters are
//   cumulative, so the next echo carries the newer total and the meter
//   self-heals. No per-packet ledger, nothing to deadlock.
//   Sustained loss is different and needs a policy. If the meter has not been
//   folded for longer than DeadIval, its readings are stale and the cap
//   RELEASES: the latch clears, the bound is not evaluated, and the link falls
//   back to plain pull. Fail-CLOSED here would let a broken REVERSE path stop
//   forward traffic -- the same class of failure as the permanent latch, by
//   another door. Failing open costs at most the mid protection the cap adds on
//   top of pull, and pull alone is the unconditional datapath (ADR-002).
//   DeadIval is not a new constant: it is main.go:29's existing "far end has
//   stopped answering" horizon, used here for the same event.
//   Test: TestCapEchoLossFailsOpen.
//
// =============================================================================
// SUBSTITUTION REGISTER -- continues pull.go's S1..S7. Every entry is OPEN.
//
//   S8  INFLIGHT IS AN ACCUMULATED PER-INTERVAL DEFICIT, NOT THE ORACLE'S TRUE
//       BACKLOG.  reserved_composite.py
//       @"inflight_kb = s.local[i].backlog_kb + s.down[i].backlog_kb" reads
//       local[i].backlog_kb + down[i].backlog_kb -- the simulator's ACTUAL queue
//       depths, which no daemon can read. The substitution is the accumulated
//       deficit described under LAG ALIGNMENT above. Known differences:
//         (a) it measures the queue's GROWTH SINCE THE LATCH, not its depth. A
//             queue that was already standing when the latch fired is invisible.
//         (b) it counts LOSS as queue. Bytes that were dropped downstream are
//             indistinguishable from bytes still queued, so a lossy latched link
//             over-estimates its queue and the gate closes earlier than it
//             should. Bounded by the latched duration, not by uptime, which is
//             why the accumulator resets on clear.
//         (c) the LOCAL half of the oracle's inflight has no counterpart. The
//             pull core's local gate is the socket refusing the write (pull.go
//             room()), which is post-hoc, so the cap's local input is the
//             REFUSAL COUNT over the window rather than a backlog in bytes.
//       U9/EQ-1 is the adjudicator, as it is for S1/S2: only a frame-for-frame
//       trace against the rig can price these.
//
//   S9  THE DELIVERED RATE IS ONE RAW INTERVAL, NOT AN EWMA.
//       masterpiece_dp.py CAP_TAU (:105) smooths it with 0.20. (:103 is CAP_W,
//       the bound-rate window -- this comment cited it by mistake.) That is another
//       undrivable constant, so no smoothing is applied and the divisor is the
//       most recent measured interval. Cost: a noisy interval moves farMS
//       directly. The latch's hysteresis damps the DECISION but not the divisor.
//       OPEN: whether smoothing is needed, and with what time constant, is an E1
//       question -- it needs the real interval-to-interval variance of the
//       delivered rate on the target path, which no model here can supply.
//
//   S10 THE DETECTION WINDOW IS AN OPERATOR INPUT, NOT A DERIVED ONE.
//       masterpiece_dp.py CAP_DET_W (:104) uses 0.400 s, justified as "> buffer, so
//       swing transients cancel" -- a justification that names a buffer nobody
//       has measured. It is required from the operator (AGG_PULL_CAP_DET_MS) and
//       E1 sizes it. The one thing enforced here is a floor of one echo interval:
//       a window shorter than the meter's own update cadence cannot contain a
//       ratio, and the cadence is PingIval (main.go:23), an existing constant
//       used for the event it already names.
//
//   S11 THE ECHO IS UNAUTHENTICATED, AND THIS CONSUMER TRUSTS IT.
//       Any host that can reach a link's socket can forge a FlagEcho with
//       arbitrary counters and drive this meter. The blast radius is bounded --
//       the cap can only REFUSE to admit, never mis-route and never corrupt the
//       resequencer -- so a forged echo is a denial of throughput on one link,
//       not a data-integrity failure, and the link still fails open once the
//       forger stops (DeadIval staleness). It is NOT fixed here: transport
//       authentication is its own unit (u31-transport-auth) and inventing a
//       half-measure would collide with it. Recorded, not silently accepted.
//       ONE MORE VECTOR, ADDED WHEN THE MARKER RING BECAME SELF-SIZING: the ring
//       now deepens itself from the ping->echo span an echo reports, so a forged
//       echo claiming an ancient txstamp asks for a deeper ring. THE BOUND IS
//       UPTIME, NOT A SMALL NUMBER, and an earlier draft of this entry sold it
//       as "a slow, visible, per-link memory growth" without saying what it
//       grows to. Stated properly, measured:
//         - growth is at most ONE marker per echo (growRing) and a marker is 12
//           bytes, but the admissible stamp range is this link's FIRST ping to
//           its most recent, and mkFirst only re-anchors at the 24.9-day epoch
//           roll. So the largest claimable span is the PROCESS UPTIME:
//           requiredMarkers(1 h) = 36,001 markers = 432,012 bytes per link, and
//           500 echoes claiming the oldest in-range stamp produced markers=501
//           grows=500 span=3599900ms.
//         - "every deepening is LOGGED" is not the mitigation it was written as.
//           It is the AMPLIFIER: one ~400-byte log line per growth step, at the
//           forger's echo rate, up to ~36,000 lines per hour of uptime, on a
//           router.
//         - retained memory is in practice bounded well below that by
//           dropMarkersUpTo while folds continue -- and that stops being true
//           exactly when folds stop, which is the inert state this file now
//           reports.
//       It remains a denial on a link the attacker can already deny outright,
//       and it is still not fixed here: authentication is U31's, and a
//       half-measure (a span ceiling) would be an invented constant. Recorded
//       with its true magnitude, not silently accepted.
//
//   S12 Admit TAKES A PER-LINK LOCK ON THE SEND HOT PATH, ONCE PER FRAME DRAW.
//       Round 1 took ONE process-wide Cap.mu for every draw on every link, which
//       serialised N Drive goroutines on a single mutex -- exactly what pull.go's
//       S2 refuses to do for the write itself. The lock is now sharded per link
//       (capLink.mu), so link i's draw contends only with link i's own echo fold
//       and its own ping marker, never with the other N-1 links. What remains is
//       one uncontended-in-the-common-case mutex per draw, held for a handful of
//       float comparisons and no syscall. It is NOT lock-free and it is NOT
//       claimed to be: measuring whether even that costs anything at the target
//       frame rate needs the box, which is G1/G3. ON-state only -- with the flag
//       off Admit is a nil-receiver call that takes no lock at all.
// =============================================================================

import (
	"encoding/binary"
	"errors"
	"fmt"
	"log"
	"strconv"
	"strings"
	"sync"
	"time"
)

// FlagEcho is the server's per-link received-count echo, 0x4.
//
// It is declared HERE rather than in frame.go because frame.go is part of the
// DEPLOYED EIF push stack and must stay byte-identical; the pull client is a
// separate entry point and this flag is only ever seen by it. The value is the
// server's, verbatim: p4-bondagg/server/frame.go:62. It must not collide with
// FlagData 0x0 / FlagPing 0x1 / FlagPong 0x2 (frame.go:26-28) or FlagFEC 0x3
// (fec.go:14).
// Test: TestCapFlagEchoDoesNotCollideWithTheShippedFlags.
const FlagEcho = 0x4

// Echo payload layout, from p4-bondagg/server/echo.go:107-118. Restated as
// constants on this side because the two modules do not share a package; a
// change on either side that is not made on both is a silent misparse, which is
// why the decoder below validates nrec against the byte length rather than
// trusting the count.
const (
	capEchoHdrLen = 6
	capEchoRecLen = 18
)

// =============================================================================
// THE MARKER RING IS SIZED BY THE MEASURED ROUND TRIP, NOT BY DeadIval.
//
// WHAT WAS WRONG, and it was silent, which is the worst part. The depth used to
// be a package constant, capMarkers = DeadIval/PingIval + 1 = 7 markers = 700 ms
// of ping history, argued from "a marker is useless once the link would be
// declared dead". That argument is about LIVENESS. The quantity a marker
// actually has to survive is the PING-TO-ECHO ROUND TRIP, and the two are
// unrelated numbers that happened to be written in the same units.
// Measured consequence, at ping->echo spans of 700 / 800 / 1200 ms: folds = 0
// and unaligned = 193 / 192 / 188. EVERY echo was unalignable, so the cap was
// enabled, consuming echoes, and measuring nothing -- SILENTLY INERT. A safety
// mechanism that is quietly inert is worse than one that is off, because the
// operator believes the path is protected.
//
// WHAT IT IS NOW. The depth is per link, starts at capMarkersInitial, and is
// DERIVED AT RUNTIME FROM A MEASUREMENT:
//
//   THE MEASUREMENT. The ping txstamp is this client's OWN clock, echoed back
//   verbatim (server/echo.go:76). So for any echo, aligned or not, the span
//   (most recent ping stamp on this link) - (this echo's stamp) is a ping->echo
//   round trip measured entirely in one clock, needing no marker and no clock
//   sync. capLink.measureSpan.
//
//   THE DERIVATION. Markers are added one per PingIval, so a marker must survive
//   span/PingIval further pings, plus itself: requiredMarkers(span) =
//   span/PingIval + 1. No chosen number appears in it. The +1 also absorbs the
//   half-cadence by which the span UNDER-states the true RTT (the newest marked
//   ping can be up to one PingIval old when the echo lands).
//
//   THE FEEDBACK. Growth is a ratchet driven by the largest span yet measured,
//   at most one marker per echo (growRing), and every deepening is LOGGED. An
//   echo whose marker was already evicted is the ONLY evidence that the ring was
//   too shallow, so it is used for sizing BEFORE it is discarded as unalignable
//   -- discarding it is precisely how the ring stayed silently too short. A path
//   at a 1200 ms span converges in about a dozen echoes, i.e. about a second.
//
//   WHERE NO MEASUREMENT EXISTS. If the stamp is not one this link ever sent
//   (a forged, foreign or stale-peer echo) there is no span and nothing grows.
//   That link is then REPORTED INERT rather than left silent: Cap.Inert,
//   CapStats.Inert, a WARNING naming the ring depth and the last span, RETRACTED
//   by a "NO LONGER INERT" line as soon as an echo aligns again, and span= / mk=
//   / INERT on the PSTAT line (pullrun.go). Inertness is a CURRENT-STATE
//   predicate -- echoes arriving and nothing aligned for a DeadIval -- not
//   "never folded"; see inertState for the measured failure of the lifetime
//   form this replaces. RTT on this
//   hardware is unmeasured -- that is G1/E1 and it is Mo's -- so this file
//   invents no RTT and asserts no depth; it measures, or it says it could not.
//
// Tests: TestCapMarkerRingSizesItselfFromTheMeasuredSpan (the fix, at spans
// 700/800/1200 ms), TestCapFixedDeadIvalRingIsInertAtRealisticSpans (the defect,
// executed against a scratch copy of the old fixed ring on the same traces),
// TestCapInertIsReportedNotSilent, TestCapMarkerRingEvictsTheOldestBeyondItsDepth.
// =============================================================================

// capMarkersInitial is the ring depth before any echo has been seen: ONE marker,
// the ping currently in flight. It is deliberately the smallest ring that can
// hold anything and it is NOT an estimate of the path -- the depth that matters
// is derived from the measured span above. No initial depth is asserted because
// no RTT has been measured on this hardware.
const capMarkersInitial = 1

// capMarker is one ping's alignment record: the client's own stamp, and the
// link's cumulative wire bytes at that instant.
type capMarker struct {
	ts   uint32
	sent uint64
}

// requiredMarkers is the ring depth a ping->echo span of spanMS demands. Markers
// are added one per PingIval, so the marker must outlive span/PingIval further
// pings, plus itself. DeadIval does not appear, and that is the whole point.
func requiredMarkers(spanMS int32) int {
	return int(spanMS/int32(PingIval/time.Millisecond)) + 1
}

// ErrCapNoDerivation is returned when the cap is switched on without one of the
// numbers only E1 can produce. It is a configuration REFUSAL, not a warning: see
// the header, "THE FLAG IS NOT THE ONLY GATE".
var ErrCapNoDerivation = errors.New("cap enabled without a required threshold")

// CapConfig is the complete set of numbers the cap needs and cannot derive.
// There is no zero-value default for any of them and this file contains no
// literal for any of them; CapConfigFromEnv refuses to build a Cap unless the
// operator supplies every one.
type CapConfig struct {
	// TargetMS is the far-inflight-time budget: the gate closes when the
	// estimated downstream queue would take longer than this to drain at the
	// measured delivered rate. Model value 40 ms: the default of the oracle's own
	// constructor, reserved_composite.py
	// @"ttl_ms=200.0, target_ms=40.0, lat_bias=False, maxq_ms=300.0", and of
	// 03-reserved-composite/ackclock_sim.py
	// @"target_ms=40.0, lat_bias=False, wmult=1.0, w_frames=None". It carries NO
	// "(*)" marking; the phrase "validated sweet spot" is masterpiece_dp.py
	// TARGET_MS (:93), and it means validated IN A SIMULATOR whose link model has
	// never been compared to a real router (ADR-004). No hardware derivation.
	TargetMS float64
	// Trip is the delivered/sent ratio below which a deficit latches the cap.
	// Model value 0.92. This one DOES carry the marking: masterpiece_dp.py
	// CAP_TRIP (:96), "(*) set for real on the hardware edge-vs-mid box test"
	// per the legend at :90-91.
	Trip float64
	// Clear is the delivered/sent ratio above which the latch releases. Model
	// value 1.5, also "(*)"-marked: masterpiece_dp.py CAP_CLEAR (:97).
	// Deliberately far from Trip: the asymmetry is the hysteresis.
	Clear float64
	// MinRateKbps is the sent rate below which a window carries too little
	// traffic to judge a ratio, so the latch HOLDS instead of moving. Model value
	// 500 kb/s: masterpiece_dp.py MINRATE (:106). NOT "(*)"-marked -- an earlier
	// version of this comment said it was, and cited :104, which is CAP_DET_W.
	MinRateKbps float64
	// DetWindow is the detector's evaluation window. Model value 400 ms:
	// masterpiece_dp.py CAP_DET_W (:104), not :101 as this comment used to say
	// (:101 is inside CAP_CLEAR's continuation text). Not "(*)"-marked either.
	// See S10 for the floor enforced on it.
	DetWindow time.Duration
}

// capLink is one link's meter. Everything in it is a counter difference or a
// latch bit; there is no estimate, no prediction and no per-path parameter.
type capLink struct {
	// mu guards this link and nothing else. Sharded per link on purpose: Admit
	// runs once per frame draw from every link's own Drive goroutine, so a single
	// process-wide mutex would serialise all N of them on the send hot path --
	// the thing pull.go's S2 refuses to do for the write itself. See S12.
	mu sync.Mutex

	// ping markers, oldest first. The DEPTH is not a constant: see the MARKER
	// RING section above. mkFirst / mkLast are the stamp range this link has ever
	// emitted, which is what makes a span measurable from an unalignable echo and
	// what keeps a foreign stamp from sizing the ring.
	mk       []capMarker
	mkCap    int
	mkAny    bool
	mkFirst  uint32
	mkLast   uint32
	rttMS    int32
	rttMaxMS int32
	mkGrow   uint64

	// the previous FOLDED reading, i.e. the other end of every interval.
	haveRx    bool
	lastRx    uint64
	lastSent  uint64
	lastSrvMS uint32
	lastFold  time.Time

	// firstEcho / lastEcho are the arrival instants of the FIRST and MOST RECENT
	// echo record this link was offered, aligned or not. They exist so inertness
	// can be a statement about the link's CURRENT state instead of its whole
	// history: see inertState.
	firstEcho time.Time
	lastEcho  time.Time

	// the measured delivered rate, bytes per millisecond, from the most recent
	// valid interval. Raw, not smoothed: S9.
	deliv    float64
	haveRate bool

	// the bound's queue estimate: the accumulated per-interval deficit since the
	// latch. Reset on clear and on re-baseline. See S8.
	queueBytes float64

	// detector accumulators over the current window.
	winStart time.Time
	winSent  float64
	winDeliv float64
	// winBp is PullLink.Bpress() sampled when the window OPENED. The detector's
	// local-congestion input is (bp now) > winBp, i.e. "did this socket refuse
	// any write during the window". Sampling it at window CLOSE instead makes
	// the comparison trivially false and silently deletes the edge exclusion
	// that keeps the cap dormant at the edge.
	winBp   uint64
	latched bool

	// diagnostics. Each counts exactly one event; none is read by the datapath.
	nFold      uint64
	nRebase    uint64
	nUnaligned uint64
	nBadIval   uint64
	nLatch     uint64
	nClear     uint64
	nRefuse    uint64

	// inertLogged is EDGE state for the inertness WARNING: set when the warning
	// is printed, cleared (with a retraction line) on the next alignment, so the
	// operator is not left holding a warning the link has already recovered from.
	// The condition itself stays readable in CapStats and on PSTAT.
	inertLogged bool
}

// Cap is the whole of E2b: one meter per link plus the latch. A nil *Cap is the
// OFF state and every method tolerates it, so the pull core carries no branch
// for the disabled case beyond the method call itself.
//
// N is len(links) and nothing else. No index is privileged: the per-link state
// is a slice, every method takes an index, and the only ceiling is the wire's
// one-byte pathID (pull.go MaxLinks / server/echo.go:8), which is checked at
// construction rather than assumed.
// Test: TestCapIsNGenericAndPermutationSymmetric.
type Cap struct {
	// cfg and link are fixed at construction and never reassigned, so neither
	// needs a lock. The per-LINK state behind link[i] is guarded by link[i].mu.
	cfg  CapConfig
	link []capLink
}

// NewCap builds a disabled-by-nobody meter over n links. It does NOT read the
// environment and does NOT decide enablement -- CapConfigFromEnv does, and it
// returns nil when the flag is off. Construction is total so tests can build any
// N; the wire ceiling is refused because a link past it emits a truncated
// pathID and the server would merge two links' counters into one record
// (server/echo.go:8, pull.go MaxLinks).
func NewCap(n int, cfg CapConfig) (*Cap, error) {
	if n < 0 || n > MaxLinks {
		return nil, fmt.Errorf("cap: %d links is outside the wire's one-byte pathID space (max %d)", n, MaxLinks)
	}
	if cfg.DetWindow < PingIval {
		// S10's floor: a window shorter than the meter's own update cadence
		// cannot contain a ratio of two readings.
		return nil, fmt.Errorf("cap: detection window %v is shorter than the echo cadence %v, "+
			"so it cannot contain two readings", cfg.DetWindow, PingIval)
	}
	c := &Cap{cfg: cfg, link: make([]capLink, n)}
	for i := range c.link {
		c.link[i].mkCap = capMarkersInitial
	}
	return c, nil
}

// N reports how many links this cap meters.
func (c *Cap) N() int {
	if c == nil {
		return 0
	}
	return len(c.link)
}

// Enabled is true only for a non-nil Cap. The nil receiver IS the off state.
func (c *Cap) Enabled() bool { return c != nil }

// MarkPing records (txstamp, cumulative sent bytes) for one link at the instant
// a ping leaves it. This is the ENTIRE mechanism behind lag alignment: without
// it there is nothing to align to and the only available difference is the
// un-aligned one that latches shut.
//
// PRECISION, stated rather than implied: sentCum is read by the caller around
// the ping write, while the link's own Drive goroutine may complete a data write
// at the same moment. PullLink.bytes is incremented AFTER its write returns, so
// the marker can miss a frame that was already in send(). The error is at most
// one in-flight frame per link -- bounded by MaxPayload+HdrLen bytes -- and it
// biases the recorded sent_cum LOW, i.e. it under-states inflight and errs
// toward admitting. Not corrected: correcting it means holding a lock across the
// write, which is the thing pull.go's S2 refuses to do.
func (c *Cap) MarkPing(link int, ts uint32, sentCum uint64) {
	if c == nil || link < 0 || link >= len(c.link) {
		return
	}
	l := &c.link[link]
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.mkAny {
		l.mkAny = true
		l.mkFirst = ts
	} else if int32(ts-l.mkFirst) < 0 {
		// THE 24.9-DAY DEATH, closed at its cause. mkFirst is the floor of
		// measureSpan's "is this stamp one we sent" range check and it was
		// anchored once, at the first ping ever. The stamp clock is uint32
		// milliseconds, so once uptime passes 2^31 ms every current stamp reads
		// as OLDER than mkFirst under int32 arithmetic, measureSpan returns no
		// span for any echo, the ring can never grow again, SpanMS freezes, and
		// the self-sizing mechanism is dead -- silently. Measured: at 24.9 days
		// of simulated uptime an ordinary echo lagged 100 ms gave span=0ms
		// grows=0 folds=0 unaligned=1. Routers run for months.
		//
		// Re-anchored to the OLDEST STAMP STILL IN RANGE that this link is known
		// to have sent: the oldest held marker if that one is itself still
		// within int32 range, else the previous ping, else this ping. No
		// constant enters -- the trigger is the wrap itself and every candidate
		// floor is existing state. The bounded cost is that echoes already in
		// flight for pings older than the new floor lose their ring-sizing
		// evidence, once, per 24.9 days of uptime.
		floor := ts
		if int32(ts-l.mkLast) >= 0 {
			floor = l.mkLast
		}
		for i := range l.mk {
			if int32(ts-l.mk[i].ts) >= 0 {
				floor = l.mk[i].ts
				break
			}
		}
		l.mkFirst = floor
		log.Printf("pull-cap: link %d ping-stamp epoch rolled at ~24.9 days of uptime; the "+
			"marker range floor is re-anchored to the oldest marker held (stamp %d). Without "+
			"this no ping->echo span is measurable again and the marker ring can never "+
			"deepen.", link, floor)
	}
	l.mkLast = ts
	l.mk = append(l.mk, capMarker{ts: ts, sent: sentCum})
	l.trimMarkers()
}

// trimMarkers drops the oldest markers beyond the ring's CURRENT depth. Caller
// holds l.mu. An evicted marker is not a lost cause: the echo that answers it
// still reports its span and still deepens the ring (foldRecord).
//
// Copy-compaction rather than a reslice, so the backing array cannot grow
// without bound on a link that never folds.
func (l *capLink) trimMarkers() {
	if len(l.mk) <= l.mkCap {
		return
	}
	n := copy(l.mk, l.mk[len(l.mk)-l.mkCap:])
	l.mk = l.mk[:n]
}

// measureSpan returns the ping->echo span in milliseconds for an echo carrying
// txstamp ts, and whether that stamp is one this link actually sent. Caller
// holds l.mu.
//
// It needs no marker, which is the whole reason the ring can size itself: an
// echo whose marker was already evicted -- the only direct evidence that the
// ring is too shallow -- still reports how deep the ring needed to be. The stamp
// is this client's own clock echoed back verbatim (server/echo.go:76), so no
// clock sync is involved here either.
//
// The span is taken against the NEWEST ping marked, which can be up to one
// PingIval older than the echo's arrival, so it UNDER-states the true round trip
// by at most one cadence. requiredMarkers' +1 covers that.
//
// The range check is what stops a forged or foreign stamp from sizing the ring:
// a stamp newer than any ping this link sent, or older than its first, yields no
// span at all. See S11. The FLOOR of that range, mkFirst, is re-anchored at the
// ~24.9-day uint32 epoch roll (MarkPing); without that every current stamp
// eventually reads as older than it and no span is ever measurable again.
func (l *capLink) measureSpan(ts uint32) (int32, bool) {
	if !l.mkAny {
		return 0, false
	}
	if int32(l.mkLast-ts) < 0 || int32(ts-l.mkFirst) < 0 {
		return 0, false
	}
	return int32(l.mkLast - ts), true
}

// growRing deepens the ring toward need, by at most ONE marker per call, and
// never shrinks. Caller holds l.mu. Reports whether it grew.
//
// One-per-call is not a tuning knob: it is the rate limit that bounds S11's
// forged-stamp growth to one 12-byte marker per echo, on a link the forger can
// already deny outright.
func (l *capLink) growRing(need int) bool {
	if need <= l.mkCap {
		return false
	}
	l.mkCap++
	l.mkGrow++
	return true
}

// lookupMarker returns the sent_cum recorded for txstamp ts, and whether it was
// found. Caller holds l.mu. Linear over the ring, which holds
// span/PingIval + 1 entries -- a low double digit even at a one-second round
// trip -- on a path that runs once per echo.
func (l *capLink) lookupMarker(ts uint32) (uint64, bool) {
	for i := range l.mk {
		if l.mk[i].ts == ts {
			return l.mk[i].sent, true
		}
	}
	return 0, false
}

// dropMarkersUpTo removes the marker for ts and every marker older than it, so a
// fold consumes its marker and everything staler. Caller holds l.mu. Without
// this a duplicated echo would fold the same interval twice.
func (l *capLink) dropMarkersUpTo(ts uint32) {
	for i := range l.mk {
		if l.mk[i].ts == ts {
			n := copy(l.mk, l.mk[i+1:])
			l.mk = l.mk[:n]
			return
		}
	}
}

// FoldEcho decodes one echo payload and folds every record whose link this
// client actually meters. txstamp is the ECHOED ping stamp from the frame
// header -- the alignment key -- and it is the client's own clock, never
// compared against the server's.
//
// It returns the number of records folded, which is a diagnostic; the datapath
// ignores it. A malformed payload folds nothing and is not an error the caller
// can act on, so it is reported as zero rather than as an error value that would
// have to be logged on the receive hot path.
//
// bpress reports each link's current PullLink.Bpress() so the detector can take
// its local-congestion difference over the same window; the caller passes it
// because Cap deliberately holds no reference to the links (nothing about the
// meter should be able to touch the datapath).
// Tests: TestCapFoldEchoDecodesTheServerSnapshotFormat,
// TestCapFoldEchoRejectsShortAndInconsistentPayloads.
func (c *Cap) FoldEcho(txstamp uint32, pay []byte, bpress []uint64, now time.Time) int {
	if c == nil || len(pay) < capEchoHdrLen {
		return 0
	}
	nrec := int(pay[0])
	srvMS := binary.BigEndian.Uint32(pay[2:6])
	if len(pay) < capEchoHdrLen+nrec*capEchoRecLen {
		// nrec disagrees with the byte length. The two modules do not share a
		// package, so a layout drift shows up exactly here; fold nothing rather
		// than read past a record boundary.
		return 0
	}
	n := 0
	for r := 0; r < nrec; r++ {
		off := capEchoHdrLen + r*capEchoRecLen
		rec := pay[off : off+capEchoRecLen]
		id := int(rec[0])
		if id < 0 || id >= len(c.link) {
			// server/echo.go:137: a record for a link this client never sent on
			// is IGNORED, not an error.
			continue
		}
		var bp uint64
		if id < len(bpress) {
			bp = bpress[id]
		}
		if c.foldRecord(id, txstamp,
			binary.BigEndian.Uint64(rec[10:18]), srvMS, bp, now) {
			n++
		}
	}
	return n
}

// foldRecord folds ONE link's reading. It takes that link's OWN lock (S12) and
// returns whether the reading was folded (an ignored or re-baselining reading
// returns false).
//
// This is where all three of echo.go's semantics are honoured; the order of the
// checks is the contract's order and is not interchangeable.
func (c *Cap) foldRecord(id int, ts uint32, rx uint64, srvMS uint32, bp uint64, now time.Time) bool {
	l := &c.link[id]
	l.mu.Lock()
	defer l.mu.Unlock()

	// ---- record that an echo ARRIVED for this link --------------------------
	// Before any decision about it. inertState needs to know that echoes are
	// still coming in, which is what separates "the cap is on and measuring
	// nothing" from "the far end has stopped answering at all" -- the second is
	// Admit's DeadIval fail-open and is a different diagnosis.
	if l.firstEcho.IsZero() {
		l.firstEcho = now
	}
	l.lastEcho = now

	// ---- size the ring from the MEASURED span, before anything else ---------
	// Done for EVERY record, aligned or not. An echo whose marker has already
	// been evicted is the only direct evidence that the ring was too shallow;
	// the old code discarded it as merely "unaligned", which is exactly how a
	// DeadIval-sized ring stayed silently inert at a 700 ms round trip. See the
	// MARKER RING section.
	if span, sok := l.measureSpan(ts); sok {
		l.rttMS = span
		if span > l.rttMaxMS {
			l.rttMaxMS = span
		}
		// Sized off the RATCHETED MAX span, not this echo's -- a ring that
		// shrank on a lucky sample would go inert again on the next slow one.
		// The log prints both, because "deepened, measured span 0 ms" would be a
		// false statement about the quantity that drove it.
		if l.growRing(requiredMarkers(l.rttMaxMS)) {
			log.Printf("pull-cap: link %d marker ring deepened to %d markers, sized by the "+
				"largest ping->echo span measured on it (%d ms; this echo's span was %d ms) at "+
				"a %v ping cadence. The depth is derived from that MEASURED span and never "+
				"from DeadIval; it grows one marker per echo and every step is logged. Until "+
				"it is deep enough this link's echoes are unalignable and the cap measures "+
				"nothing for it.", id, l.mkCap, l.rttMaxMS, span, PingIval)
		}
	}

	sentAt, ok := l.lookupMarker(ts)
	if !ok {
		// No marker for this stamp: either the echo answers a ping older than
		// the marker ring, or it is not answering a ping this client sent. There
		// is nothing to align against, so there is no reading. Do NOT fall back
		// to sent_cum(now) -- that is precisely the un-aligned difference this
		// whole mechanism exists to avoid.
		l.nUnaligned++
		if !l.inertLogged && l.inertState() {
			// REPORT INERTNESS, do not be silently inert. Echoes are arriving and
			// NOTHING HAS ALIGNED FOR A WHOLE DeadIval, so the cap is enabled,
			// consuming them, and protecting nothing -- whether or not this link
			// ever folded in the past. See inertState for why the "ever folded"
			// form was wrong.
			l.inertLogged = true
			log.Printf("pull-cap: link %d INERT -- echoes are still arriving but NOTHING has "+
				"aligned to a ping marker for %v, so the cap is ON and measuring nothing for "+
				"it RIGHT NOW. folds=%d unaligned=%d ring=%d markers span=%dms cadence=%v. If "+
				"the ring is still sizing itself this retracts within a few echoes and a "+
				"\"NO LONGER INERT\" line follows; if it does not, the stamps are not ours "+
				"(stale peer, forgery, a server that stopped echoing) or the round trip has "+
				"outgrown a ring that can no longer measure its own span.",
				id, DeadIval, l.nFold, l.nUnaligned, l.mkCap, l.rttMS, PingIval)
		}
		return false
	}
	l.dropMarkersUpTo(ts)
	l.nFold++
	l.lastFold = now
	if l.inertLogged {
		// RETRACT it. A warning that latches for the life of the process is a
		// warning the operator learns to ignore, and the round-1 convergence case
		// (a ring still sizing itself) fires it legitimately and then recovers.
		l.inertLogged = false
		log.Printf("pull-cap: link %d NO LONGER INERT -- an echo aligned to a ping marker. "+
			"folds=%d unaligned=%d ring=%d markers span=%dms.",
			id, l.nFold, l.nUnaligned, l.mkCap, l.rttMS)
	}

	// ---- semantic 1: a REGRESSION is a server restart. Re-baseline. ----------
	// Not a clamp at zero (echo.go:36-39): a clamp would hide the restart and
	// hold a stale, too-large inflight. The latch is cleared with it -- a restart
	// is not evidence of a downstream deficit, and leaving it latched would hold
	// the gate shut on the strength of a reading that no longer exists.
	if l.haveRx && rx < l.lastRx {
		l.nRebase++
		c.rebase(l, rx, sentAt, srvMS, bp, now)
		return false
	}
	if !l.haveRx {
		// First reading ever on this link. Same treatment for the same reason:
		// there is no earlier counter to difference against, and the client may
		// have been sending long before the first echo arrived, so an absolute
		// difference here would charge all of that history to inflight.
		//
		// It counts as a REBASE, which is what CapStats.Rebases has always said
		// it counts ("server restarts (counter regressions) + the first
		// reading") and what the tests have always asserted -- the increment was
		// simply missing, and nothing executed this file until CI compiled it.
		// Without it PSTAT shows fold=1 rb=0 on a link that produced no reading,
		// with nothing on the line explaining why.
		l.nRebase++
		c.rebase(l, rx, sentAt, srvMS, bp, now)
		return false
	}

	// ---- semantic 2: srvMS is uint32, wraps, and is WALL clock ---------------
	// uint32 subtraction then int32 interpretation: the same wrap-safe idiom
	// ring.go uses for seq (ring.go @"int32(seq-r.next) < 0"). A naive int64
	// subtraction
	// produces a ~4.29e9 ms denominator once per wrap and reports a delivered
	// rate of about zero (echo.go:95-99).
	dms := int32(srvMS - l.lastSrvMS)
	if dms <= 0 || sentAt < l.lastSent {
		// dms <= 0: the server's WALL clock stepped backwards (NTP), or two
		// snapshots landed inside one millisecond. There is no denominator.
		// sentAt < lastSent: the client's own counter cannot regress within a
		// process lifetime, so the markers were consumed out of order.
		//
		// Either way there is no reading, so the interval is SKIPPED: the
		// baselines re-anchor on the NEW values (holding the old ones would
		// freeze the meter for the whole size of a backward clock step) and the
		// rate is dropped, which fails this link OPEN through Admit's deadlock
		// break until a real interval exists again.
		//
		// IT IS NOT A REBASE, AND THAT IS THE FIX. Round 2 routed this into
		// rebase(), which clears the latch and zeroes the queue accumulator, so
		// a single NTP step on the server -- a live path, echo.go says srvMS is
		// wall clock -- released a mid-deficit latch. Measured on the runner:
		// before "latched=true clears=0 bad=0", after one dms<=0 reading
		// "latched=false clears=1 bad=1". A broken clock is not evidence that a
		// downstream deficit ended, and it was a FOURTH latch exit inside the
		// block that declares the list of exits complete. See skipInterval.
		l.nBadIval++
		c.skipInterval(l, rx, sentAt, srvMS)
		return false
	}
	dRx := float64(rx - l.lastRx)
	dSent := float64(sentAt - l.lastSent)

	l.deliv = dRx / float64(dms) // bytes per millisecond
	l.haveRate = true

	// ---- the bound's queue estimate: accumulate the interval DEFICIT ---------
	// (sent in) - (came out) over one interval. WHAT THAT QUANTITY IS depends on
	// which regime the path is in, and the file header names both rather than
	// picking one: under REGIME B (the ping overtakes the standing backlog) it is
	// the growth of the hidden downstream queue, which is what the bound wants;
	// under REGIME A (the ping is a strict FIFO byte marker) it is the bytes LOST
	// in that interval and farMS stops meaning a drain time. Which one holds is
	// E1's to answer. Accumulated only while latched either way, so its drift is
	// bounded by the latched duration (S8). Clamped at zero because neither a
	// queue nor a loss count can be negative -- this is NOT the counter clamp
	// echo.go forbids, which is about hiding a restart in a cumulative
	// difference.
	if l.latched {
		l.queueBytes += dSent - dRx
		if l.queueBytes < 0 {
			l.queueBytes = 0
		}
	}

	// ---- the detector's window ----------------------------------------------
	// The window always has an open stamp and a Bpress baseline: every link's
	// first fold is a rebase, and rebase opens the window.
	l.winSent += dSent
	l.winDeliv += dRx
	if now.Sub(l.winStart) >= c.cfg.DetWindow {
		c.evaluate(l, bp, now)
	}

	l.lastRx = rx
	l.lastSent = sentAt
	l.lastSrvMS = srvMS
	return true
}

// rebase installs a fresh baseline: the point from which every subsequent
// difference is taken. Used for the first reading and after a server restart.
// Caller holds l.mu.
//
// It clears the latch and the queue accumulator because both were built out of
// readings that no longer connect to the counters now on the wire. Leaving
// either in place is how "re-baseline" degenerates back into the permanent latch
// (echo.go:29-39, "arriving by the other door").
func (c *Cap) rebase(l *capLink, rx uint64, sentAt uint64, srvMS uint32, bp uint64, now time.Time) {
	l.haveRx = true
	l.lastRx = rx
	l.lastSent = sentAt
	l.lastSrvMS = srvMS
	l.haveRate = false
	l.deliv = 0
	l.queueBytes = 0
	if l.latched {
		l.nClear++
	}
	l.latched = false
	l.winStart = now
	l.winSent = 0
	l.winDeliv = 0
	l.winBp = bp
}

// skipInterval re-anchors the meter for an interval that produced NO usable
// reading, and touches nothing else. Caller holds l.mu.
//
// The difference from rebase is the whole point of the function: rebase exists
// for events that invalidate the DETECTOR'S EVIDENCE (a server restart, the
// first reading), so it clears the latch and the queue accumulator. A
// non-positive srvMS interval invalidates only the DENOMINATOR -- the byte
// counters on both ends are still cumulative, monotone and connected -- so the
// latch, the queue accumulator, the clear counter and the detector window are
// all left exactly as they were.
//
// The rate IS dropped. That is deliberate and it is what keeps this from
// creating a new permanent-latch path: with no rate, Admit takes the deadlock
// break and returns true, so a server whose clock never advances degrades to
// plain pull with its latch bit intact, rather than sitting shut on a stale
// divisor. The cost is one interval's bytes missing from the detector window,
// which is bounded and self-heals on the next echo.
// Test: TestCapBadIntervalIsNotALatchExit.
func (c *Cap) skipInterval(l *capLink, rx uint64, sentAt uint64, srvMS uint32) {
	l.lastRx = rx
	l.lastSent = sentAt
	l.lastSrvMS = srvMS
	l.haveRate = false
	l.deliv = 0
}

// evaluate runs the DETECTOR over the closed window and resets it. Caller holds
// l.mu.
//
// The three-way outcome -- latch, clear, hold -- and the asymmetry between Trip
// and Clear are the hysteresis. See the header.
func (c *Cap) evaluate(l *capLink, bp uint64, now time.Time) {
	winMS := float64(now.Sub(l.winStart)) / float64(time.Millisecond)
	localCongested := bp > l.winBp

	// Too little traffic to judge: HOLD, do not move the latch in either
	// direction. An idle window has no evidence in it, and reading its ratio
	// would let an idle path clear a latch it never tested.
	// sent kb/s = bytes*8/1000 / (ms/1000) = bytes*8/ms.
	sentKbps := 0.0
	if winMS > 0 {
		sentKbps = l.winSent * 8.0 / winMS
	}
	if sentKbps < c.cfg.MinRateKbps {
		if localCongested && l.latched {
			// The one thing an idle window still proves: the local socket
			// refused writes, so the regime is edge and the latch is wrong.
			l.latched = false
			l.queueBytes = 0
			l.nClear++
		}
		c.resetWindow(l, bp, now)
		return
	}

	r := l.winDeliv / l.winSent
	switch {
	case r < c.cfg.Trip && !localCongested:
		// The pure MID signature: the socket took everything and the far end
		// delivered less.
		if !l.latched {
			l.latched = true
			l.queueBytes = 0
			l.nLatch++
		}
	case r > c.cfg.Clear || localCongested:
		if l.latched {
			l.latched = false
			l.queueBytes = 0
			l.nClear++
		}
	default:
		// HOLD. A well-controlled mid path sits here at r ~= 1.0 and stays
		// latched; a symmetric band would flap.
	}
	c.resetWindow(l, bp, now)
}

func (c *Cap) resetWindow(l *capLink, bp uint64, now time.Time) {
	l.winStart = now
	l.winSent = 0
	l.winDeliv = 0
	l.winBp = bp
}

// Admit is the CAP half of room(). It answers one question -- may this link draw
// a frame right now -- and it is consulted BEFORE the draw, which is where the
// oracle consults room()
// (reserved_composite.py @"cand = [i for i in range(s.N) if room(i)]").
//
// It returns true, i.e. it does not interfere, in every case where it lacks
// evidence. That is not leniency, it is the E1 gate expressed in code: the cap
// is a refinement on top of pull, and pull alone is the unconditional datapath
// (ADR-002), so absent evidence the correct behaviour is plain pull.
//
//	nil Cap            the flag is off
//	not latched        no mid deficit detected -- dormant, by construction, at
//	                   the edge (the detector's local-uncongested conjunction)
//	no delivered rate  THE DEADLOCK BREAK, not a bootstrap case. See below.
//	stale meter        no echo folded for longer than DeadIval: fail OPEN, and
//	                   release the latch with it (see ECHO LOSS in the header)
//
// THE DEADLOCK BREAK IS THE ONLY THING PREVENTING A PERMANENT LATCH, AND IT USED
// TO BE DOCUMENTED AS SOMETHING ELSE ("no rate yet -- nothing has been
// measured", which describes only the first half of the condition it guards).
// Written out, because a load-bearing safety property must not rest on a line
// whose comment describes a different purpose:
//
//	deliv is measured from bytes the FAR END RECEIVED. Refusing to admit is the
//	one thing that stops those bytes existing. So a refusal taken while
//	deliv == 0 REPRODUCES ITS OWN PRECONDITION: no admission, so nothing sent,
//	so dRx == 0, so deliv == 0, so refuse again, for ever.
//	farMS = queueBytes/deliv is +Inf at deliv == 0, so the gate is closed on
//	every evaluation.
//	Nothing else breaks it. Pings are NOT gated by Admit, so echoes keep
//	arriving and folding, lastFold keeps advancing, and the DeadIval staleness
//	fail-open above never fires. And with no data sent the detector's window
//	falls under MinRateKbps, which takes evaluate()'s "too little traffic to
//	judge" arm -- that arm HOLDS the latch and refuses to move it, so the latch
//	cannot clear either. A quiet link would be capped shut permanently.
//
// DEMONSTRATED, NOT ASSERTED. TestCapZeroRateGuardIsWhatPreventsAPermanentLatch
// runs one trace through a scratch copy of this function with the guard deleted
// (admitWithoutZeroRateGuard, cap_test.go, the same idiom as unalignedInflight)
// and shows it never reopens, then runs the identical trace through this
// function and shows it does.
//
// The !haveRate limb is the same property before any interval has existed at
// all, and it stays in the same condition because it has the same consequence.
//
// Tests: TestCapAdmitIsDormantWhileUnlatched, TestCapBoundClosesWhenQueueTimeExceedsTarget,
// TestCapEchoLossFailsOpen, TestCapDefaultOffAdmitsEverythingForAnyN,
// TestCapZeroRateGuardIsWhatPreventsAPermanentLatch.
func (c *Cap) Admit(link int, now time.Time) bool {
	if c == nil || link < 0 || link >= len(c.link) {
		return true
	}
	l := &c.link[link]
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.latched {
		return true
	}
	if !l.lastFold.IsZero() && now.Sub(l.lastFold) > DeadIval {
		l.latched = false
		l.queueBytes = 0
		l.haveRate = false
		l.nClear++
		return true
	}
	// THE DEADLOCK BREAK. Refusing on a zero delivered rate would guarantee the
	// rate stays zero. See the block comment above.
	if !l.haveRate || l.deliv <= 0 {
		return true
	}
	farMS := l.queueBytes / l.deliv
	if farMS < c.cfg.TargetMS {
		return true
	}
	l.nRefuse++
	return false
}

// FarMS reports the current estimated far-inflight time in milliseconds and
// whether it is meaningful. Diagnostic only; the PSTAT line prints it so E1 can
// see what the cap was seeing. Nothing in the datapath reads it.
func (c *Cap) FarMS(link int) (float64, bool) {
	if c == nil || link < 0 || link >= len(c.link) {
		return 0, false
	}
	l := &c.link[link]
	l.mu.Lock()
	defer l.mu.Unlock()
	if !l.haveRate || l.deliv <= 0 {
		return 0, false
	}
	return l.queueBytes / l.deliv, true
}

// Latched reports the detector's latch bit for one link. Diagnostic and test
// accessor.
func (c *Cap) Latched(link int) bool {
	if c == nil || link < 0 || link >= len(c.link) {
		return false
	}
	l := &c.link[link]
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.latched
}

// DelivBytesPerMs reports the measured delivered rate for one link and whether a
// valid interval has produced one. Diagnostic and test accessor.
func (c *Cap) DelivBytesPerMs(link int) (float64, bool) {
	if c == nil || link < 0 || link >= len(c.link) {
		return 0, false
	}
	l := &c.link[link]
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.deliv, l.haveRate
}

// CapStats is one link's diagnostic counters. Each field counts exactly one
// event so a log line never conflates two diagnoses -- the same discipline
// pull.go applies to stale / qdrop / retq.
type CapStats struct {
	Folds     uint64 // records folded with a marker found
	Rebases   uint64 // server restarts (counter regressions) + the first reading
	Unaligned uint64 // echoes whose txstamp matched no marker: NOT folded
	BadIvals  uint64 // srvMS interval <= 0, or markers consumed out of order
	Latches   uint64
	Clears    uint64
	Refusals  uint64 // Admit returned false
	Latched   bool
	Markers   int    // current marker-ring depth, derived from the measured span
	Grows     uint64 // times the ring deepened itself
	SpanMS    int32  // most recent measured ping->echo span, client clock
	Inert     bool   // echoes arriving, nothing aligned for a DeadIval: measuring nothing
}

// Stats reports one link's counters.
func (c *Cap) Stats(link int) CapStats {
	if c == nil || link < 0 || link >= len(c.link) {
		return CapStats{}
	}
	l := &c.link[link]
	l.mu.Lock()
	defer l.mu.Unlock()
	return CapStats{
		Folds:     l.nFold,
		Rebases:   l.nRebase,
		Unaligned: l.nUnaligned,
		BadIvals:  l.nBadIval,
		Latches:   l.nLatch,
		Clears:    l.nClear,
		Refusals:  l.nRefuse,
		Latched:   l.latched,
		Markers:   l.mkCap,
		Grows:     l.mkGrow,
		SpanMS:    l.rttMS,
		Inert:     l.inertState(),
	}
}

// inertState is the inertness predicate. Caller holds l.mu.
//
// IT IS A STATEMENT ABOUT NOW, NOT ABOUT THE LINK'S WHOLE LIFE, and round 2
// shipped the lifetime form: `nFold == 0 && nUnaligned > 0`. That reports
// inertness only for a link that has NEVER folded, so a link that folded once
// and then stopped folding -- the round trip outgrowing a ring that can no
// longer measure its own span, a stale peer, a server that stops echoing our
// stamps -- read INERT=false for ever while the cap sat on it consuming echoes
// and measuring nothing. Measured on the runner: one fold followed by 199
// unalignable echoes read folds=1 unaligned=199 INERT=false. That is the SAME
// silent-inertness class round 1 shipped, moved rather than closed, and
// Admit's DeadIval limb hides it further by returning true, so there is no
// other symptom either.
//
// The predicate now is: echoes ARE arriving, and NOTHING has aligned for longer
// than DeadIval.
//
//	firstEcho / lastFold is the "last progress" instant -- an alignment, or the
//	moment the first echo arrived if there has never been one. A link that has
//	only just started is therefore NOT inert, which also removes the spurious
//	startup warning: pullrun stamps each link's ping inside the per-link loop, so
//	a loop that crosses a millisecond boundary gives link 1 a stamp link 0's echo
//	cannot match, and the lifetime form fired a permanent WARNING on that single
//	echo before link 1 had folded anything.
//
// DeadIval is not a new constant here either: it is main.go's existing "the far
// end has stopped answering" horizon, and it is the same horizon Admit's
// fail-open uses, so the two diagnoses are cut at the same place.
//
// NAMED LIMITATION, because it is real: the instant of evaluation is the LAST
// ECHO's arrival, not wall-clock now. If echoes stop arriving altogether the
// flag freezes at whatever it last was. That is deliberate -- Cap holds no
// clock, Stats takes no `now`, and a link with no echoes at all is a different
// diagnosis owned by Admit's DeadIval fail-open, which RELEASES the cap. So the
// frozen value can be stale by one horizon; it cannot claim protection that is
// not there.
// Tests: TestCapInertIsReportedNotSilent,
// TestCapInertIsCurrentStateNotLifetime.
func (l *capLink) inertState() bool {
	if l.lastEcho.IsZero() || l.nUnaligned == 0 {
		return false
	}
	ref := l.lastFold
	if ref.IsZero() {
		ref = l.firstEcho
	}
	return l.lastEcho.Sub(ref) > DeadIval
}

// Inert reports that echoes for this link are arriving and NOTHING has aligned
// to a ping marker for longer than DeadIval: the cap is enabled, consuming
// echoes, and measuring nothing RIGHT NOW. It exists because the failure this
// unit shipped in round 1 was SILENT inertness, and a safety mechanism that is
// quietly doing nothing is worse than one that is off -- the operator believes
// the path is protected.
//
// It is deliberately a plain predicate over the counters and timestamps rather
// than a separate flag, so it cannot drift away from what they say.
// Tests: TestCapInertIsReportedNotSilent, TestCapInertIsCurrentStateNotLifetime.
func (c *Cap) Inert(link int) bool {
	if c == nil || link < 0 || link >= len(c.link) {
		return false
	}
	l := &c.link[link]
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.inertState()
}

// ---------------------------------------------------------------------------
// CONFIGURATION -- the flag, and the refusal that makes the flag safe.
// ---------------------------------------------------------------------------

// capEnvKeys is the exact set an operator must supply to switch the cap on. It
// is a list rather than a series of ifs so the refusal message can name every
// missing one at once, and so the test can assert the set without duplicating it.
var capEnvKeys = []string{
	"AGG_PULL_CAP_TARGET_MS",
	"AGG_PULL_CAP_TRIP",
	"AGG_PULL_CAP_CLEAR",
	"AGG_PULL_CAP_MINRATE_KBPS",
	"AGG_PULL_CAP_DET_MS",
}

// CapConfigFromEnv reports whether the cap is enabled and, if so, with what.
//
// DEFAULT IS OFF. AGG_PULL_CAP must be exactly "on"; anything else, including
// unset, is off, and off returns (false, zero, nil) so the caller builds no Cap
// at all.
//
// Switched ON, every value in capEnvKeys is REQUIRED and there is no default for
// any of them. That is the E1 gate made structural. All five are un-derived, for
// the two distinct reasons set out in the file header:
//   - masterpiece_dp.py CAP_TRIP (:96) and CAP_CLEAR (:97) carry the "(*)" the
//     legend (:90-91) defines as "set for real on the hardware edge-vs-mid box
//     test" -- i.e. the file itself says they are placeholders.
//   - TARGET_MS (:93), CAP_DET_W (:104) and MINRATE (:106) carry no marking and
//     are "validated model values". Validated in a simulator whose link model has
//     never been compared to a real router (ADR-004's open condition, and the
//     ROADMAP standing risks), which is not hardware evidence either.
//
// Shipping any of them as a default would make this file the source of five
// invented constants; refusing to start makes it the source of none.
//
// getenv is injected so the test can drive it without mutating process
// environment shared with other tests running in parallel.
// Tests: TestCapDefaultOffAdmitsEverythingForAnyN (the default and what OFF means),
// TestCapConfigRequiresEveryUnderivedNumber, TestCapConfigAcceptsACompleteSet,
// TestCapConfigRejectsNonsenseValues.
func CapConfigFromEnv(getenv func(string) string) (bool, CapConfig, error) {
	var cfg CapConfig
	if getenv("AGG_PULL_CAP") != "on" {
		return false, cfg, nil
	}
	var missing []string
	vals := make(map[string]float64, len(capEnvKeys))
	for _, k := range capEnvKeys {
		s := getenv(k)
		if s == "" {
			missing = append(missing, k)
			continue
		}
		// strconv.ParseFloat, NOT fmt.Sscan. Sscan stops at the first token and
		// reports no error for the rest, so "0.92 junk" parsed to 0.92 with err
		// nil -- an operator typo or a mangled env line became a silently
		// accepted threshold on a safety mechanism. ParseFloat requires the
		// WHOLE string. Test: TestCapConfigRejectsNonsenseValues, the
		// trailing-garbage rows.
		f, perr := strconv.ParseFloat(strings.TrimSpace(s), 64)
		if perr != nil || !(f > 0) {
			return false, cfg, fmt.Errorf("cap: %s=%q is not a positive number", k, s)
		}
		vals[k] = f
	}
	if len(missing) > 0 {
		return false, cfg, fmt.Errorf(
			"%w: AGG_PULL_CAP=on but %v are unset. Every one of them is a number NOBODY HAS "+
				"DERIVED, for two different reasons. TRIP (0.92) and CLEAR (1.5) are marked "+
				"in masterpiece_dp.py (:96, :97) as \"set for real on the hardware "+
				"edge-vs-mid box test\" -- the model calls them placeholders. TARGET (40ms), "+
				"WINDOW (400ms) and MINRATE (500kb/s) are NOT so marked (:93, :104, :106); "+
				"they are model values validated only inside a simulator that has never been "+
				"compared to a real router (ADR-004). That test is G1/E1 and it has not run "+
				"(ROADMAP.md, the G1 row in EPIC 5). This build ships no default for any of "+
				"them ON PURPOSE, so "+
				"the cap cannot be enabled before the experiment that produces its numbers. "+
				"Supply them explicitly to run E1 itself, knowing they are unvalidated",
			ErrCapNoDerivation, missing)
	}
	cfg.TargetMS = vals["AGG_PULL_CAP_TARGET_MS"]
	cfg.Trip = vals["AGG_PULL_CAP_TRIP"]
	cfg.Clear = vals["AGG_PULL_CAP_CLEAR"]
	cfg.MinRateKbps = vals["AGG_PULL_CAP_MINRATE_KBPS"]
	cfg.DetWindow = time.Duration(vals["AGG_PULL_CAP_DET_MS"]) * time.Millisecond
	if cfg.Clear <= cfg.Trip {
		return false, cfg, fmt.Errorf(
			"cap: AGG_PULL_CAP_CLEAR=%g must exceed AGG_PULL_CAP_TRIP=%g -- the gap between "+
				"them IS the hysteresis, and a non-positive gap turns latch-and-hold into a "+
				"flap on every window", cfg.Clear, cfg.Trip)
	}
	return true, cfg, nil
}

// LogCapPosture prints what the cap is doing and, critically, the provenance of
// every number behind it. Same posture as pull.go's txBackoff line: an operator
// value with no derivation is logged AS an operator value with no derivation.
func LogCapPosture(on bool, cfg CapConfig, n int) {
	if !on {
		log.Print("pull-cap: OFF (default). E2b is BUILT and DISABLED: the delivered-rate cap " +
			"exists only for a hidden MID-network bottleneck, and whether this hardware has " +
			"one is what G1/E1 measures (ROADMAP.md, the G1 row in EPIC 5). With the flag " +
			"off nothing in this " +
			"build consults the server echo for admission and the datapath is plain pull. " +
			"AGG_PULL_CAP=on additionally REQUIRES every threshold explicitly -- there is no " +
			"default for any of them, because none has been derived.")
		return
	}
	log.Printf("pull-cap: ON over %d link(s). EVERY NUMBER BELOW IS AN OPERATOR VALUE WITH NO "+
		"DERIVATION BEHIND IT -- G1/E1 is the experiment that derives them and it has not run. "+
		"target=%.1fms trip=%.3f clear=%.3f minrate=%.0fkbps window=%v. Meter: lag-aligned off "+
		"the server echo (sent_cum at the echoed ping txstamp, client clock only); rate from "+
		"srvMS intervals, wrap-safe. Counter regression = server restart = re-baseline, never a "+
		"clamp. No echo for %v = fail OPEN back to plain pull.",
		n, cfg.TargetMS, cfg.Trip, cfg.Clear, cfg.MinRateKbps, cfg.DetWindow, DeadIval)
}
