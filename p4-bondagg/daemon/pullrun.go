package main

// =============================================================================
// U7 / E2a -- client wiring for the PULL core (AGG_MODE=pull-client).
//
// Runnable shell around pull.go. It was written as a SEPARATE entry point
// alongside the EIF push client, which was then the default; U128 deleted the
// push entry points (ADR-002 / U127), so as of that commit this is the ONLY
// datapath the binary has and AGG_MODE=pull-client is the only accepted mode.
//
// The send side is the whole point and it is four lines: read a WG datagram,
// hand it to the pool, done. No Pick, no ETA, no backup path, no suspect-window
// duplicate -- all of that was push-side machinery the pivot deleted.
//
// The receive side and the control cadence are deliberately UNCHANGED reuse of
// already-validated pieces: Ring (ring.go -- nsched_model.reorder_release names
// ring.go as the thing it models), OWD (paths.go), RxEstSet (qtrack2.go) and
// LossMeter (fec.go).
//
// CONSTANTS -- the accurate statement, replacing an earlier one that was true
// but misleading. E2a introduces no NEW constant. It does, however, take an
// EXISTING flagged one and apply it to a quantity it was not derived for:
//   * owd.Hold(HoldMin, HoldMax) = clamp(spread + 3*jit + 250, 150ms, 350ms)
//     (paths.go:102) is on the HANDOFF record (2026-08-29, "No arbitrary
//     constants") as owed a derivation. U13/OBJ-B owns deriving it.
//   * that hold is a RECEIVER-side reorder budget. Here it is ALSO the SENDER-
//     side pool residence budget (core.TrimAll). Same number, different
//     physical quantity, and U13 does not close the second use -- U13 derives
//     the receiver hold. Nobody owns a derived sender residence budget yet.
//   * "no new constant enters" is therefore true and beside the point. Recorded
//     as an OPEN divergence: pull.go S4.
// The one number this file DOES choose, the pool's byte ceiling, is derived from
// a kernel measurement (sum of SO_SNDBUF), logged with its provenance, and
// overridable -- see pull.go S3 for why it is not the oracle's quantity.
//
// PEERING. This client talks to the EXISTING AGG_MODE=server, which already does
// the E3 receive job (unpack -> ring.Push by seq -> forward to WG). The
// server->client direction is still the push design until U16/E3 lands. That is
// why the ping/pong exchange is kept: the unchanged server needs its pong surface
// to run its own downlink scheduler. The pull client itself consumes NONE of it
// except liveness -- it has no uplink rate controller to feed.
// =============================================================================

import (
	"fmt"
	"log"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

func runPullClient() {
	listen := env("AGG_LISTEN", "127.0.0.1:59402")
	serverStr := env("AGG_SERVER", "")
	if serverStr == "" {
		log.Fatal("AGG_SERVER host:port required")
	}
	// U36a: still NO default path list -- the two-interface literal this used to
	// refuse to inherit is now deleted from the push entry points as well, so
	// there is nothing left anywhere to inherit. What replaces the refusal is the
	// same resolver the push client uses: AGG_PATHS verbatim when set (the
	// reconciler is the discoverer and always wins), otherwise the devices that
	// currently carry an up default route, otherwise a loud refusal because the
	// box has no uplink. All three entry points now answer this question the same
	// way, in one tested place. See discover.go.
	devs := mustSources("pull-client")

	// ---- U17a: AGG_SCHED, read BEFORE anything is built ------------------
	//
	// It is resolved first because an unimplemented value is a REFUSAL and a
	// refusal must happen before this process binds a socket. `bond-xctl` emits
	// this fact into agg_env and both procd stanzas pass it; until this unit the
	// daemon read AGG_MODE and AGG_PATHS out of that same environment and
	// dropped AGG_SCHED on the floor, so `max` and `speed` were byte-identical
	// on the wire and `bondctl mode speed` silently did `max`.
	//
	// U138: it also takes N, because `eco` IS the N=1 datapath and is REFUSED at
	// any other arity -- the same rule the DAG guard sources_for_mode enforces
	// from the other side. devs is resolved above, so N is known here, which is
	// before any socket is bound.
	sched, schedSet, schedErr := SchedFromEnv(func(k string) string { return env(k, "") }, len(devs))
	if schedErr != nil {
		log.Fatalf("pull-client: %v", schedErr)
	}
	if schedSet {
		log.Printf("pull-client: AGG_SCHED=%s -> %s", sched.Name, sched.Describe())
	} else {
		log.Printf("pull-client: AGG_SCHED unset -- INHERITING %q, which is the datapath "+
			"this daemon ran before AGG_SCHED existed, not a choice anyone made. A stanza "+
			"that predates U17 lands here. %s", SchedInherited, sched.Describe())
	}

	srv, err := net.ResolveUDPAddr("udp4", serverStr)
	if err != nil {
		log.Fatal("resolve server: ", err)
	}
	la, _ := net.ResolveUDPAddr("udp4", listen)
	wgSock, err := net.ListenUDP("udp4", la)
	if err != nil {
		log.Fatal("listen: ", err)
	}
	N := len(devs)
	// The ceiling this entry point used to enforce inline is now enforced inside
	// the resolver (discover.go wireCeiling), for every entry point, with the same
	// bound and the same reason: pathID is ONE BYTE (frame.go:9), so past MaxLinks
	// byte(idx) wraps and two links emit the same id -- the peer discovers one link
	// where two exist and merges their OWD, LossMeter and fseq series, which
	// FABRICATES per-path loss out of two interleaved sub-sequences. mustSources
	// has already refused if N > MaxLinks, and TestWireCeilingRefusesAboveMaxLinks
	// is the bar. Empty and whitespace-only entries are rejected there too
	// (splitPaths), so both checks moved rather than being dropped.

	// ---- AGG_W: the pull path takes NO per-path prior (U36) ----
	//
	// The push client reads AGG_W into a per-path weight vector that seeds
	// CapEst's initial Chat and Sched's AIMD floor/start rate, so an asymmetric
	// vector privileges paths. The pull core has neither an estimator nor a rate
	// controller, so there is nothing for a prior to seed. AGG_W is therefore
	// UNREAD here, in either direction: unset, empty and set all produce the same
	// N-symmetric state. Stated and logged rather than left implicit, because
	// "nobody reads it" is invisible to an operator who has just set it and to
	// the next person wiring something into this file.
	if v := env("AGG_W", ""); v != "" {
		log.Printf("pull: AGG_W=%q IGNORED. The pull core consumes no per-path "+
			"capacity prior -- it has no CapEst and no AIMD rate controller to seed, "+
			"so every link starts identical and the datapath is symmetric under "+
			"permutation of AGG_PATHS. Set AGG_W only for AGG_MODE=client|server (the "+
			"retained EIF push reference), where it is positional and does bind.", v)
	}

	pc := make([]*net.UDPConn, N)
	for i := 0; i < N; i++ {
		pc[i], err = devConn(devs[i])
		if err != nil {
			log.Fatalf("path %s: %v", devs[i], err)
		}
	}
	core := NewPullCore(devs, pc, srv)
	log.Printf("pull-client: %s -> %s via %v (N=%d)", listen, serverStr, devs, core.N())

	// U138: the POOL SHAPE has to exist before the byte limb is installed below,
	// because under fan-out the limb is per-link and there is no single pool to
	// install it on. ApplySched (further down, once the ring exists) is still the
	// ONE place a policy becomes datapath state and it re-asserts this -- the
	// call is idempotent, which is why asserting the shape early is not a second
	// source of truth. Nil FIFOs (every mode but `lightning`) is the shared pool
	// and nothing below changes.
	core.SetFanout(sched.Fanout)
	if core.Fanout() {
		log.Printf("pull-tx: FAN-OUT ON (AGG_SCHED=%s). %d per-link pools, one seq per "+
			"offer enqueued into every one of them: every source carries every frame. "+
			"There is no duplicator and no trigger. First copy wins at the peer by the "+
			"seq dedup the ring already does; a dead or refusing source sheds only its "+
			"OWN copies, by the age limb of its own pool. The DOWNLINK is still ONE "+
			"copy -- every DATA frame carries hint d=(0-idx) so the server pins it to "+
			"AGG_PATHS[0]=%s (pull.go send).", sched.Name, core.N(), devs[0])
	}

	// U17a: `max` builds no Ranker and installs no gate, so every line this unit
	// added is unreachable in that mode. `speed` builds one Ranker over N -- N is
	// len(Links) and nothing else, no index privileged. The ring is applied
	// below, once it exists; ApplySched is the one place the policy becomes
	// datapath state and it is the thing a test can execute.
	ranker := NewRankerFor(sched, core.N())

	// ---- FRAMING AUTHENTICATION (U31). This is the client half of the gate ----
	//
	// Same posture as the server (server/main.go): a missing or unusable key
	// file is NOT fatal. The client IS the recoverable box (HANDOFF 0a), but a
	// daemon that refuses to start over a config file is still the wrong
	// failure, and a keyless gate is byte-for-byte the pre-U31 wire.
	//
	// ONE gate for all N links, not one per link: the peer is one server, a tag
	// verified on any link is proof about the peer, and SendAuth's silence
	// fallback must not fire because a single link went quiet. N enters here
	// exactly nowhere -- see authTX in pull.go.
	//
	// The reopen horizon is floored the same way and for the same reason as the
	// server's (auth.go ReopenFloor): the gate is CLOSED only for `reopen` after
	// each verified frame, so a horizon shorter than the peer's liveness timer
	// leaves it OPEN between frames.
	keyPath := env("AGG_KEY_FILE", KeyFileDefault)
	keys, kerr := LoadKeys(keyPath)
	if kerr != nil {
		log.Printf("auth: cannot read %s (%v)", keyPath, kerr)
	}
	reopen := clampReopen(envMS("AGG_AUTH_REOPEN_MS", ReopenDefault))
	atx := &authTX{gate: newAuthGate(keys, reopen, roleClient)}
	core.SetAuth(atx)
	if atx.gate.Enabled() {
		log.Printf("auth: %d key(s) from %s, reopen horizon %v, sealing uplink DATA, "+
			"pings and pongs", len(keys), keyPath, reopen)
	} else {
		log.Printf("auth: OFF -- no usable key in %s. Frames are sent unsigned and "+
			"every well-formed frame from every source is accepted, which is the "+
			"pre-U31 posture: one forged frame can move the downlink and one forged "+
			"seq can cost a hold of uplink", keyPath)
	}

	// ---- the pool's BYTE limb: derived, logged, overridable (pull.go S3) ----
	//
	// The oracle bounds the pool by bytes every tick, maxq_kb =
	// (maxq_ms/1000)*sum(cap0). sum(cap0) is the per-path NOMINAL CAPACITY set,
	// which this daemon does not have and will not invent -- AGG_W's numbers are
	// deliberately not inherited. So the oracle's bound cannot be ported as
	// written and something else has to carry the byte limb.
	//
	// Derived default: sum over links of SO_SNDBUF, read from the kernel here.
	// It is measured rather than chosen, it is N-generic (a sum over Links, no
	// index privileged, no per-path constant), and it has a defensible meaning --
	// the userspace pool may hold at most what the system has already agreed to
	// buffer for these same sockets. It is NOT the oracle's quantity; the three
	// ways it differs are written out in pull.go S3, including that Linux reports
	// SO_SNDBUF at twice the value set.
	//
	// This is a MEMORY-SAFETY ceiling with a stated derivation, not a tuned
	// number, and E1 is what replaces it: the correct bound is a residence-time
	// budget over MEASURED aggregate delivered rate, and E1 is the experiment
	// that produces the rate.
	//
	// UNDER FAN-OUT the same derivation applies PER POOL, because there is one
	// pool per link and each holds only what THAT link will send: the bound on
	// link i's pool is link i's own SO_SNDBUF, and the sum over the pools is
	// therefore the identical total the shared pool carries today. No new number
	// enters, and no link's pool is bounded by another link's kernel buffer.
	snd := make([]int, len(core.Links))
	sumSnd, unknown := 0, 0
	for i := range core.Links {
		b := core.Links[i].SndBuf()
		snd[i] = b
		// G1/E1 input: how much local queue "the socket accepted it" permits.
		log.Printf("pull-link %d dev=%s sndbuf=%d", i, core.Links[i].Ifname(), b)
		if b > 0 {
			sumSnd += b
		} else {
			unknown++
		}
	}
	maxq := sumSnd
	src := fmt.Sprintf("derived sum(SO_SNDBUF) over %d link(s)", N-unknown)
	if unknown > 0 {
		log.Printf("pull-pool WARNING: SO_SNDBUF unreadable on %d of %d links; the "+
			"derived byte bound is summed over the readable ones only and is that "+
			"much LOOSER than intended", unknown, N)
	}
	ovr := false
	if v := env("AGG_PULL_MAXQ_BYTES", ""); v != "" {
		var n int
		if _, e := fmtSscan(v, &n); e == nil && n > 0 {
			maxq, src, ovr = n, "AGG_PULL_MAXQ_BYTES (operator override, NO derivation)", true
		} else {
			log.Printf("pull-pool: AGG_PULL_MAXQ_BYTES=%q not a positive int, ignored", v)
		}
	}
	if maxq <= 0 {
		// Nothing to derive from and no override. Do not pick a number: run with
		// the byte limb OFF and say so, loudly. The age limb still bounds the
		// pool in time; what is unbounded here is DEPTH under a burst shorter
		// than the hold.
		log.Printf("pull-pool WARNING: byte bound DISABLED -- no readable SO_SNDBUF on "+
			"any of %d links and no AGG_PULL_MAXQ_BYTES. The pool is bounded in AGE "+
			"only; a burst shorter than the reorder hold is unbounded in depth.", N)
	} else if !core.Fanout() {
		core.FIFO.SetMaxBytes(maxq)
		log.Printf("pull-pool: maxq=%d bytes (%s); age limb = owd.Hold(%v,%v) -- see "+
			"pull.go S3/S4, both limbs are OPEN divergences from the oracle",
			maxq, src, HoldMin, HoldMax)
	} else {
		// Fan-out: one bound per pool, each derived from ITS OWN link. An
		// operator override is a single number and there is no per-link form of
		// it, so it applies to every pool and is logged as the total it then
		// implies -- N times the number the operator wrote, which is the thing
		// they have to be told.
		tot := 0
		for i := range core.FIFOs {
			b := snd[i]
			if ovr {
				b = maxq
			}
			if b <= 0 {
				log.Printf("pull-pool WARNING: link %d (%s) has no readable SO_SNDBUF and "+
					"there is no override; ITS pool runs with the byte limb OFF, bounded "+
					"in AGE only. The other pools are unaffected.", i, core.Links[i].Ifname())
				continue
			}
			core.FIFOs[i].SetMaxBytes(b)
			tot += b
		}
		note := ""
		if ovr {
			note = " OVERRIDDEN by AGG_PULL_MAXQ_BYTES on every pool"
		}
		log.Printf("pull-pool: FAN-OUT, %d pools, maxq PER POOL = that link's own "+
			"SO_SNDBUF (%v)%s; total %d bytes over the set -- the same quantity the "+
			"shared pool carries, split per link. Age limb = owd.Hold(%v,%v) on every "+
			"pool -- see pull.go S3/S4.", len(core.FIFOs), snd, note, tot, HoldMin, HoldMax)
	}

	// ---- backpressure backoff: default is NO invented duration (pull.go) ----
	if v := env("AGG_PULL_TXBACKOFF_US", ""); v != "" {
		var us int
		if _, e := fmtSscan(v, &us); e == nil && us >= 0 {
			txBackoff = time.Duration(us) * time.Microsecond
		} else {
			log.Printf("pull-tx: AGG_PULL_TXBACKOFF_US=%q not a non-negative int, ignored", v)
		}
	}
	if txBackoff <= 0 {
		log.Printf("pull-tx: backpressure backoff = WAIT FOR DRAIN EVIDENCE (no sleep, " +
			"no invented duration). A refused link parks until another link's write " +
			"SUCCEEDS (the only direct evidence a device is draining), until the control " +
			"tick Wakes, or until close. It does NOT wake on new work or on a rollback: " +
			"neither says a device is draining, and while a rollback did, two refusing " +
			"links woke each other at CPU speed. The derived value would need a device " +
			"drain rate and the pull pivot has no rate estimator, so no duration is " +
			"picked. Worst case -- every link refusing, offer idle -- the retry rate is " +
			"the control tick, not the CPU (pull.go DRAIN WAKE SET; asserted for N in " +
			"1,2,3,5 by TestPullDriveEveryLinkRefusingDoesNotSpinForAnyN). Set " +
			"AGG_PULL_TXBACKOFF_US to substitute a real sleep.")
	} else {
		log.Printf("pull-tx: backpressure backoff = %v (AGG_PULL_TXBACKOFF_US, "+
			"operator value, NO derivation behind it)", txBackoff)
	}

	// ---- E2b: the delivered-rate CAP. OFF by default (cap.go) ----------------
	//
	// Enablement is E1's decision (p5-execution-handover.md
	// @"E2b/E2c/E3/E4/E5/E6 built (cap+lightning *enablement* set by E1)",
	// ROADMAP.md @"| U15a | E2b **CAP**"),
	// so this build ships it BUILT and DISABLED. AGG_PULL_CAP=on additionally
	// requires every threshold explicitly -- none of them has a derivation and
	// this build carries no default for any of them, so the flag cannot be
	// switched on before G1/E1 has produced the numbers.
	capOn, capCfg, capErr := CapConfigFromEnv(func(k string) string { return env(k, "") })
	if capErr != nil {
		log.Fatalf("pull-cap: %v", capErr)
	}
	var capm *Cap
	if capOn {
		capm, err = NewCap(N, capCfg)
		if err != nil {
			log.Fatalf("pull-cap: %v", err)
		}
		core.SetCap(capm)
	}
	LogCapPosture(capOn, capCfg, N)

	// U15b/E2c: standing spotty-class lightning. nil == OFF, which is the
	// default; every method below is nil-safe so nothing branches on it.
	lit := NewLightning(core, devs)

	// ---- receive side: downlink -> reorder ring -> WG ----
	owd := NewOWD(N)
	rxEst := NewRxEstSet(pullNoPrior(N))
	lossM := make([]*LossMeter, N)
	for i := 0; i < N; i++ {
		lossM[i] = &LossMeter{}
	}
	sLossE := make([]float64, N)
	delivBytes := make([]uint64, N)
	lossByte := make([]uint32, N)

	var rxDeliver, rxSkip, rxShed uint64
	var wgAddr *net.UDPAddr
	var wgMu sync.Mutex
	ring := NewRing(11, HoldMin, func(b []byte) {
		atomicAdd(&rxDeliver, 1)
		wgMu.Lock()
		a := wgAddr
		wgMu.Unlock()
		if a != nil {
			wgSock.WriteToUDP(b, a)
		}
	})
	ring.OnSkip = func() { atomicAdd(&rxSkip, 1) }
	// U17a: BOTH halves of the policy become datapath state here, in one call,
	// before any RX goroutine exists and before core.Start (ApplySched says why
	// each of those matters). The DELIVERY half is the one that differs
	// UNCONDITIONALLY -- it needs no statistics and no cooperation from the peer,
	// so it is what stops `speed` from collapsing back onto `max` when the echo
	// surface is dead.
	if err := ApplySched(sched, core, ring, ranker); err != nil {
		// U138: the arity refusal. Fatal here for the reason SchedFromEnv's
		// unknown-value refusal is fatal -- a mode the datapath cannot serve as
		// named is a disagreement with the orchestration, not a degradation.
		log.Fatalf("pull-client: %v", err)
	}
	if sched.Delivery == DeliverOnArrival {
		log.Printf("pull-rx: DELIVER ON ARRIVAL (AGG_SCHED=%s). The ring dedups and "+
			"nothing else: no hold, no in-order release, no straggler skip. Frames reach "+
			"WG out of order by design -- the application's own jitter buffer is the "+
			"reorder point, and a second buffer in series is what this mode removes. "+
			"Dedup retention is the ring's SIZE IN SEQS, not a duration.", sched.Name)
	}

	for i := 0; i < N; i++ {
		go func(p int) {
			// MaxAuthFrame, not MaxFrame. A sealed full-size frame is
			// MaxFrame+MacLen, and a buffer of MaxFrame truncates it by exactly
			// the trailer -- which is indistinguishable from a bad tag, so the
			// link would fail closed with authbad climbing and nothing saying
			// why. See daemon/auth.go BUFFER SIZES; pinned by
			// TestPullRxBufferHoldsASealedFullSizeFrame.
			buf := make([]byte, MaxAuthFrame)
			// Reused across echoes so the receive path allocates nothing per
			// frame. Only meaningful while the cap is on; FoldEcho is a
			// nil-receiver no-op otherwise.
			bpress := make([]uint64, N)
			for {
				n, _, err := pc[p].ReadFromUDP(buf)
				if err != nil {
					continue
				}
				now := time.Now()
				// INTEGRATION POINT 2 (daemon/auth.go): Admit is the ONLY entry
				// point to the header. It parses, verifies, strips the trailer
				// and sheds a forgery while the gate is closed. With no key
				// loaded it passes everything, which is the pre-U31 behaviour.
				f, v := atx.gate.Admit(buf[:n], now)
				switch v {
				case admitMalformed:
					continue
				case admitShed:
					atomicAdd(&rxShed, 1)
					continue
				}
				atx.MarkRx(now)
				core.Links[p].MarkRx()
				sq, ts, fseq, pay := f.seq, f.ts, f.fseq, f.pay
				switch f.base {
				case FlagPing:
					// The unmodified server still runs the push downlink and
					// needs its surface echoed back. Answer it verbatim.
					rxEst.Fold(p, float64(int32(nowMS()-ts)))
					qb, od, jt := rxEst.Echo(p)
					lp := byte(atomic.LoadUint32(&lossByte[p]))
					du := uint16(atomic.LoadUint64(&delivBytes[p]) / 256)
					pr := make([]byte, HdrLen+pongLen+MacLen)
					pm := Pack(pr, FlagPong, byte(p), 0, ts, 0,
						[]byte{lp, qb, od, jt, byte(du >> 8), byte(du)})
					if sm := atx.Seal(pr, pm, now); sm >= 0 {
						pc[p].WriteToUDP(pr[:sm], srv)
					}
				case FlagPong:
					// Liveness only (MarkRx above). The pull core has no uplink
					// rate controller and no capacity estimate to feed.
					//
					// U17a: except the rank, and this case is NOT redundant with
					// FlagEcho below -- the two servers answer a client ping with
					// DIFFERENT flags, and getting this wrong would have left
					// `speed` with zero samples against the peer it actually
					// talks to today:
					//   PUSH server (AGG_MODE=server, main.go @"case FlagPing:
					//     // client's ping: fold for the uplink floor + reply
					//     w/ surface") replies FlagPong, ts echoed verbatim.
					//     This is TODAY's peer -- see this file's PEERING block.
					//   E3 thin server (p4-bondagg/server) replies FlagEcho,
					//     ts echoed verbatim (server/echo.go).
					// Either way ts is THIS client's own ping txstamp, so the
					// round trip is measured in one clock. Whichever arrives
					// resolves the probe; the other finds nothing pending and is
					// ignored, so wiring both cannot double-count.
					ranker.Echo(p, ts, time.Now())
				case FlagEcho:
					// E2b: E3's per-link cumulative received-count snapshot
					// (server/echo.go). ts is the client's OWN ping txstamp,
					// echoed back verbatim -- it is the alignment key, and the
					// only reason this meter can be lag-aligned with no clock
					// sync at all (cap.go, LAG ALIGNMENT).
					//
					// EVERY link's counters ride in EVERY echo (echo.go:101), which
					// is what keeps the meter alive when one link's reverse path
					// breaks; a record for a link this client never sent on is
					// ignored (echo.go:137). An echo is never forwarded to WG and
					// touches no ring state.
					//
					// With the cap OFF, capm is nil and this case does nothing at
					// all: an echo costs one Unpack and one branch.
					//
					// U17a: the echo is ALSO the rank's only sample, and it is
					// the right one for a reason worth stating rather than
					// assuming. ts here is THIS CLIENT'S OWN ping txstamp,
					// echoed back verbatim, so now-ts is a round trip measured
					// end to end in ONE clock -- the only latency quantity in
					// this daemon that does not carry an unknown client/server
					// clock offset, and therefore the only one that can be
					// compared against an absolute deadline at all (sched.go
					// S8). It also arrives on EVERY link at PingIval whether or
					// not that link is drawing, which is exactly the idle-path
					// probe the model does not have and the design says the real
					// daemon does (sec 3.6): a vacated path stays ranked and can
					// be re-promoted when it recovers.
					//
					// Nil-safe: with AGG_SCHED=max ranker is nil and this is one
					// branch.
					ranker.Echo(p, ts, time.Now())
					if capm != nil {
						for k := 0; k < N; k++ {
							bpress[k] = core.Links[k].Bpress()
						}
						capm.FoldEcho(ts, pay, bpress, time.Now())
					}
				case FlagData:
					rxEst.Fold(p, float64(int32(nowMS()-ts)))
					owd.Sample(p, ts)
					hd := owd.Hold(HoldMin, HoldMax)
					ring.SetHold(hd)
					lossM[p].Data(fseq, time.Now(), hd)
					atomic.AddUint64(&delivBytes[p], uint64(n))
					ring.Push(sq, pay, time.Now())
				}
				// FlagFEC is ignored: the pull core sends no parity (FEC is
				// falsified and closed), and the unmodified server only emits it
				// if it believes the downlink is lossy. Dropping a parity frame
				// costs a recovery, never correctness.
			}
		}(i)
	}

	// ---- control cadence: pings, liveness, ring tick, pool trim, STAT ----
	go func() {
		// HdrLen+MacLen: a sealed ping is 24 bytes, not 16. An UNAUTHENTICATED
		// ping draws no echo on a link the server has never seen DATA on
		// (server/rx.go), so an unsealed ping is not merely unsigned, it is
		// answered less -- and the same trailer room is what stops Seal writing
		// past the end of this buffer.
		pb := make([]byte, HdrLen+MacLen)
		lastStat := time.Now()
		lastLoss := time.Now()
		for {
			now := time.Now()
			for i := 0; i < N; i++ {
				// E2b LAG ALIGNMENT, and this is the whole mechanism. The ping
				// carries this client's OWN txstamp; the server echoes it back
				// VERBATIM (server/echo.go:76). Recording the link's cumulative
				// sent bytes AT THIS INSTANT is what lets the echo, whenever it
				// arrives, be differenced against the sent counter FROM THE SAME
				// POINT IN THE BYTE STREAM -- in one clock, this one, with no
				// clock sync. Without this line the only available difference is
				// sent_cum(now) - rxBytes, which charges a whole round trip of our
				// own sending to inflight and latches the cap permanently shut
				// (cap.go LAG ALIGNMENT; the failure is EXECUTED by
				// TestCapUnalignedDifferenceWouldLatchOnTheSameCleanTrace).
				//
				// Bytes() is read BEFORE the ping write, so the marker cannot
				// include a data frame sent after the ping entered the queue. It
				// can still MISS one that a Drive goroutine is inside send() for;
				// that is bounded by one frame per link and biases toward
				// admitting (cap.go MarkPing).
				//
				// With the cap off, MarkPing is a nil-receiver no-op.
				ts := nowMS()
				capm.MarkPing(i, ts, core.Links[i].Bytes())
				// U17a: the same ping, the same stamp, one more consumer. The
				// rank's outstanding-probe record is what turns an UNANSWERED
				// ping into a deadline miss, which is how hhat fuses loss and
				// latency with no coefficient at all. Nil-safe under `max`.
				ranker.Ping(i, ts, time.Now())
				m := Pack(pb, FlagPing, byte(i), 0, ts, 0, nil)
				if sm := atx.Seal(pb, m, now); sm >= 0 {
					pc[i].WriteToUDP(pb[:sm], srv)
				}
				core.Links[i].SetAlive(core.Links[i].RxAge(now) <= DeadIval)
			}
			hd := owd.Hold(HoldMin, HoldMax)
			ring.Tick(now)
			// Pool bound, AGE limb. Trim also INSTALLS hd on the pool so that
			// Enqueue and Return apply the same limb between ticks -- the bound
			// is no longer a 100 ms sampled thing (pull.go S5).
			//
			// hd is the SAME hold the ring uses, so no second constant enters.
			// That is true and it is not a defence: hd = clamp(spread+3*jit+250,
			// 150, 350) (paths.go:102) is ALREADY on the HANDOFF record as owed a
			// derivation, and here it is additionally being reused for a
			// different physical quantity -- receiver reorder spread governing
			// SENDER residence. Logged as an open divergence, pull.go S4. U13's
			// derived hold does NOT close it: U13 derives the receiver hold.
			core.TrimAll(now, hd)
			// U15b/E2c: same cadence, same hd. The copy queue's TTL IS this
			// hold (the design's TTL), and like the pool it applies both limbs
			// on every mutation too -- this only installs hd and re-bounds.
			lit.Tick(now, hd)
			// Release drawers parked on an empty pool so a link that just went
			// dead (or came back) re-evaluates its own gate.
			core.WakeAll()
			if now.Sub(lastLoss) >= LossIval {
				lastLoss = now
				// U17a: hhat's window IS this epoch. Reusing the existing loss
				// cadence is the whole reason the rank introduces no new
				// constant -- the design's sec 9 row 4 names LWIN for exactly
				// this. Nil-safe under `max`.
				ranker.Epoch(now)
				for i := 0; i < N; i++ {
					wl, wt := lossM[i].Window(now, hd)
					if wt > 0 {
						sLossE[i] = sLossE[i]*0.7 + (float64(wl)/float64(wt)*100.0)*0.3
					}
					lp := byte(min64(200, int64(sLossE[i]*2+0.5)))
					atomic.StoreUint32(&lossByte[i], uint32(lp))
				}
			}
			if now.Sub(lastStat) > time.Second {
				lastStat = now
				depth, peak, enq, drawn, stale := core.Stats()
				qb, qbPeak, qbMax, qdrops, retq := core.ByteStats()
				var sb strings.Builder
				// stale = shed by the AGE limb, qdrop = shed by the BYTE limb,
				// retq = backpressure rollbacks. Kept as three numbers: which
				// limb is shedding, and whether the links are refusing, are
				// different diagnoses and E1 reads them separately.
				// U17a: sched= is FIRST after n= and it is not decoration. A log
				// that does not say which scheduler produced the numbers below
				// it cannot be used to tell the two aggregate modes apart, which
				// is the exact ambiguity this unit closes. hold= reads 0ms under
				// `speed` because nothing is waiting, not because nothing was
				// measured.
				// authok/authbad/authshed and the gate flag are the ONLY way to
				// tell an authenticated tunnel from an unauthenticated one at
				// run time: FlagAuth is a wire bit nobody can see from here, the
				// gate fails OPEN by design, and a wrong macRole verifies
				// nothing while looking healthy (ROADMAP U31 open question 5).
				// rxshed is where a forgery dies; sealshort should be zero
				// forever and names a TX buffer sized without the trailer.
				aok, abad, ashed := atx.gate.Counts()
				shut := 0
				if atx.gate.Closed(now) {
					shut = 1
				}
				fmt.Fprintf(&sb, "PSTAT n=%d sched=%s depth=%d peak=%d qb=%d/%d peakb=%d enq=%d drawn=%d stale=%d qdrop=%d retq=%d hold=%dms del=%d skip=%d rxshed=%d authok=%d authbad=%d authshed=%d sealshort=%d gate=%d",
					core.N(), sched.Name, depth, peak, qb, qbMax, qbPeak, enq, drawn, stale, qdrops, retq,
					ring.HoldDur().Milliseconds(),
					atomic.LoadUint64(&rxDeliver), atomic.LoadUint64(&rxSkip),
					atomic.LoadUint64(&rxShed), aok, abad, ashed,
					atx.gate.SealShort(), shut)
				for i := range core.Links {
					l := core.Links[i]
					// E1's three send-side counters. Each means ONE thing; the
					// discriminator is the RELATION between them, not any one of
					// them, and an earlier revision that nominated a single
					// counter as "the" discriminator was wrong (pull.go).
					//   blk   wall time REFUSED + waiting to retry. Exactly 0 on a
					//         link whose writes all succeed: it carries no
					//         per-write syscall floor and does not grow with
					//         throughput.
					//   bp    how many writes were refused.
					//   wravg mean time inside a SUCCESSFUL write.
					//   wrmin the SMALLEST successful write ever seen on this
					//         link -- the measured per-write syscall floor on
					//         this box. -1 until the first success.
					// Read: bp>0 -> edge, ENOBUFS refuse regime. bp=0 and
					// wravg >> wrmin -> edge, netpoller park regime. bp=0 and
					// wravg ~= wrmin -> the writer is never held up; if RTT is
					// climbing at the same time that is MID. err is path-down
					// only and never backpressure.
					var wravg int64
					if s := l.Sent(); s > 0 {
						wravg = l.WriteNs() / int64(s)
					}
					fmt.Fprintf(&sb, " | %s sent=%d kb=%d blk=%dms bp=%d wravg=%dns wrmin=%dns err=%d up=%v",
						l.Ifname(), l.Sent(), l.Bytes()/1024, l.BlockedMs(), l.Bpress(),
						wravg, l.WriteFloorNs(), l.Errs(), l.Alive())
					// U17a, printed only under `speed` so a `max` line is
					// byte-identical to the one this unit found. def/defms are
					// the rank deferral -- DELIBERATELY not folded into blk,
					// which is E1's edge discriminator and means "the device
					// refused", not "our own policy declined to offer".
					if ranker != nil {
						fmt.Fprintf(&sb, " def=%d defms=%d gate=%v%s",
							l.Defers(), l.DeferMs(), !l.GateClosed(), ranker.Stat(i))
					}
					// E2b, printed only when the cap is ON so the OFF line is
					// byte-identical to U7's. cap=1/0 is the latch; far is the
					// estimated far-inflight time the bound compares against
					// target; rb counts server restarts (counter regressions)
					// plus the one first-reading baseline.
					//
					// READ **INERT** FIRST, NOT unal. INERT means echoes are
					// still arriving and NOTHING has aligned to a ping marker
					// for a whole DeadIval, i.e. the cap is on and measuring
					// nothing RIGHT NOW (cap.go inertState). It retracts by
					// itself, and a "NO LONGER INERT" log line says so.
					//
					// unal IS NOT AN ERROR RATE AND AN EARLIER VERSION OF THIS
					// COMMENT SAID IT WAS ("the alignment failing and the number
					// to read first"). On a healthy N-link client it reads about
					// (N-1)x fold BY CONSTRUCTION: this loop sends one ping per
					// link per cadence, the server answers EACH ping with an
					// echo carrying EVERY link's records (server/echo.go,
					// server/main.go:299-305), and the N pings of a cadence
					// usually share a millisecond. So each link folds on the
					// first echo to arrive, that fold consumes its only marker,
					// and the other N-1 echoes of the cadence count unaligned.
					// Measured at zero lag: unal/fold = 0 / 1 / 2 / 4 at
					// N = 1 / 2 / 3 / 5 (TestCapUnalignedIsNMinusOnePerFold).
					// What unal is good for is its RATIO to fold: much above
					// N-1 means alignment is genuinely failing.
					//
					// span/mk are the marker ring making itself legible: span is
					// the MEASURED ping->echo round trip in the client's own
					// clock and mk is the ring depth derived from it (cap.go,
					// THE MARKER RING).
					if capm != nil {
						cs := capm.Stats(i)
						far, haveFar := capm.FarMS(i)
						farStr := "n/a"
						if haveFar {
							farStr = fmt.Sprintf("%.1fms", far)
						}
						lat := 0
						if cs.Latched {
							lat = 1
						}
						inert := ""
						if cs.Inert {
							inert = " INERT"
						}
						fmt.Fprintf(&sb, " cap=%d far=%s fold=%d unal=%d rb=%d bad=%d refuse=%d span=%dms mk=%d/%d%s",
							lat, farStr, cs.Folds, cs.Unaligned, cs.Rebases, cs.BadIvals, cs.Refusals,
							cs.SpanMS, cs.Markers, cs.Grows, inert)
					}
				}
				// U15b/E2c: empty string when lightning is off, so a flag-down
				// run prints exactly what it printed before this unit existed.
				sb.WriteString(lit.Stat())
				log.Print(sb.String())
			}
			time.Sleep(PingIval)
		}
	}()

	// U15b/E2c: nil lit calls core.Start() verbatim -- U7's Drive loop, not
	// this unit's. Deleting lightning is: delete lightning*.go and revert the
	// four lines in this file marked U15b.
	lit.Start(core)

	// ---- send side: THE INVERSION. The reader picks no path. ----
	buf := make([]byte, MaxPayload)
	for {
		n, ra, err := wgSock.ReadFromUDP(buf)
		if err != nil {
			continue
		}
		wgMu.Lock()
		wgAddr = ra
		wgMu.Unlock()
		core.Offer(buf[:n], time.Now())
	}
}

// =============================================================================
// U36 -- "AGG_W unset = no prior", stated on the PULL path, which is where the
// shipped datapath is going. This is the whole of U36's code.
//
// WHAT THE PUSH REFERENCE DID, and where it is now. Its two entry points
// resolved `parseW(env("AGG_W", "20000,15000"), N)`: with AGG_W unset or empty,
// path 0 got a 20000 kb/s prior, path 1 a 15000 kb/s prior, and every remaining
// path fell through to parseW's own 10000 -- a privileged constant on a client
// that declares four WAN interfaces. U36 deliberately did not edit that code,
// because it was the frozen P4 reference. U128 DELETED it instead (ADR-002 as
// amended by U127: the reference is now the annotated tag
// `eif-push-reference`), so the latent constant is no longer on this tree at
// all. `parseW` itself survives in main.go for one reason, stated there: it is
// the positive control for the bars below.
//
// WHAT THE PULL PATH DOES. It reads no weights at all. There is no CapEst and no
// AIMD rate controller in the pull core (pull.go N-GENERICITY), so a per-path
// prior has nothing to seed. The ONE per-path PRIOR this file constructs is
// RxEstSet's priorOwd, and it is built by pullNoPrior. The file's other per-path
// slices -- NewOWD(N), the LossMeter array, sLossE, delivBytes, lossByte -- are
// zero-valued STATE rather than priors: each is Go's zero value for its type, none
// is seeded from a constant, and none distinguishes an index. Stated per slice so
// this is a checkable claim and not a sweep.
//
// WHY A FUNCTION AND NOT `make([]float64, N)` INLINE. A named function is
// something a test can execute and a future edit has to walk past. The bars in
// pullaggw_test.go assert that its output is flat for N in {1,2,3,4,5,8,16,256},
// is invariant under permutation, and does not move for ANY value of AGG_W --
// including the exact literal the push default carries. Wiring AGG_W into this
// path later fails those bars instead of silently reintroducing a prior.
//
// NOT A DERIVATION, AND NOT A BEHAVIOUR CHANGE. The vector is zeros, which is
// byte-for-byte what this call site already passed (make([]float64, N)) and what
// the two push entry points still pass. What is new here is the NAME and the
// bars, not the value.
//
// WHAT THE SEED ACTUALLY DOES, read rather than assumed, because an earlier draft
// of this comment asserted a mechanism the code does not have. RxEstSet uses
// priorOwd ONLY until the first real sample folds: floorUpdate REPLACES the floor
// with the windowed min over filled buckets (e.floor = mn, NOT min(seed, mn)) on
// the very first fold, every downstream consumer is gated on floorInit which only
// a real fold sets, and relQF is likewise overwritten on the first gated fold
// because NewRxEstSet leaves relQFInit false. So the seed governs the
// pre-first-sample window and nothing after it. Zero is "no measurement", not
// "measured zero" -- the value that asserts nothing about a path before anything
// has been measured, and the same on every path. That is the whole claim; it is
// not a general claim that zero is the right prior for anything else, and no
// other quantity in the pull path is seeded from it.
//
// OPEN QUESTION, carried not answered: what a MEASURED per-source prior would be
// and whether an a-priori prior speeds convergence or biases it. Unmeasured on
// this hardware, and no test here can measure it -- these bars bound the vector's
// SHAPE, never its value. E1/G1 is the experiment.
func pullNoPrior(n int) []float64 { return make([]float64, n) }
