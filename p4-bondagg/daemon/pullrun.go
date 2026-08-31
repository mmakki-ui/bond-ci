package main

// =============================================================================
// U7 / E2a -- client wiring for the PULL core (AGG_MODE=pull-client).
//
// Runnable shell around pull.go. It is a SEPARATE entry point: runClient (the
// EIF push client) is untouched and still the default, so this cannot regress
// the shipped daemon.
//
// The send side is the whole point and it is four lines: read a WG datagram,
// hand it to the pool, done. No Pick, no ETA, no backup path, no suspect-window
// duplicate -- all of that was push-side machinery the pivot deleted.
//
// The receive side and the control cadence reuse already-validated pieces: Ring
// (ring.go -- nsched_model.reorder_release names ring.go as the thing it
// models), RxEstSet (qtrack2.go) and LossMeter (fec.go).
//
// CONSTANTS -- rewritten by U13, because the statement below it used to be true
// and is not any more.
//   * THE RING'S REORDER HOLD IS NOW DERIVED. It is hold.go's LatenessRatchet:
//     H := max(H, t_arrival - t_blockStart) over frames the ring discarded, with
//     ring.go's own >=10ms floor (:148-153) and its own 2^11 window (:139-141)
//     as the only bounds. paths.go:102's clamp(spread + 3*jit + 250, 150, 350)
//     no longer governs it. Derivation, the two candidate observations that were
//     MEASURED and rejected, and the honest caveats: hold.go.
//   * paths.go:102's formula SURVIVES, in one place, for one consumer: the
//     SENDER-side pool residence budget (core.FIFO.Trim), as hold.go's
//     formulaHold. That reuse of a RECEIVER reorder spread as sender residence
//     is divergence S4, and U13 does NOT close it -- a sender residence budget
//     is a different physical quantity and its derivation needs E1's measured
//     aggregate delivered rate. What U13 changes is that the ring no longer
//     shares the number, so S4 is now one formula with one consumer instead of
//     one formula silently governing two quantities.
//   * The OWD tracker is hold.go's pullOWD, not paths.go's: identical EWMA
//     arithmetic, MONOTONIC clock. paths.go:13 nowMS() is time.Now().UnixMilli()
//     and paths.go is frozen (it carries the deployed push client), so the pull
//     path carries its own. The push client still reads the wall clock.
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
	pathsStr := env("AGG_PATHS", "")
	if serverStr == "" {
		log.Fatal("AGG_SERVER host:port required")
	}
	// No default path list. The push client's "eth1,usb0" default is a
	// 2-source assumption; the pull core refuses to inherit it.
	if pathsStr == "" {
		log.Fatal("AGG_PATHS ifname[,ifname...] required")
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
	devs := strings.Split(pathsStr, ",")
	for i := range devs {
		devs[i] = strings.TrimSpace(devs[i])
		if devs[i] == "" {
			log.Fatalf("AGG_PATHS: empty ifname at position %d", i)
		}
	}
	N := len(devs)
	// The one ceiling the pull core inherits, enforced where an operator can see
	// it rather than silently truncated. pathID is ONE BYTE (frame.go:9), so past
	// MaxLinks byte(idx) wraps and two links emit the same id: the peer discovers
	// one link where two exist and merges their OWD, LossMeter and fseq series,
	// which FABRICATES per-path loss out of two interleaved sub-sequences. Refuse
	// to start instead. Same bound, same reason, on the server: server/echo.go:8.
	if N > MaxLinks {
		log.Fatalf("AGG_PATHS lists %d sources but the wire addresses paths with a ONE-BYTE "+
			"pathID, so at most %d are distinguishable (pull.go MaxLinks, frame.go:9). "+
			"Links 0 and %d would both emit pathID 0 and the peer would merge their OWD, "+
			"loss and fseq series. Refusing to start rather than fabricate per-path loss.",
			N, MaxLinks, MaxLinks)
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
	sumSnd, unknown := 0, 0
	for i := range core.Links {
		b := core.Links[i].SndBuf()
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
	if v := env("AGG_PULL_MAXQ_BYTES", ""); v != "" {
		var n int
		if _, e := fmtSscan(v, &n); e == nil && n > 0 {
			maxq, src = n, "AGG_PULL_MAXQ_BYTES (operator override, NO derivation)"
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
	} else {
		core.FIFO.SetMaxBytes(maxq)
		log.Printf("pull-pool: maxq=%d bytes (%s); age limb = formulaHold(%v,%v), "+
			"the SENDER residence budget -- see pull.go S3/S4, both limbs are OPEN "+
			"divergences from the oracle. The RING's hold is derived separately "+
			"(hold.go LatenessRatchet) and is no longer the same number.",
			maxq, src, HoldMin, HoldMax)
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

	// ---- receive side: downlink -> reorder ring -> WG ----
	//
	// U13: the reorder hold is DERIVED (hold.go LatenessRatchet), not computed
	// from paths.go:102's formula. `owd` is now pullOWD -- identical EWMA
	// arithmetic, monotonic clock -- and its ONLY consumer is the sender-side
	// Trim below, which is divergence S4. See hold.go formulaHold.
	owd := newPullOWD(N)
	rxEst := NewRxEstSet(make([]float64, N))
	lossM := make([]*LossMeter, N)
	for i := 0; i < N; i++ {
		lossM[i] = &LossMeter{}
	}
	sLossE := make([]float64, N)
	delivBytes := make([]uint64, N)
	lossByte := make([]uint32, N)

	var rxDeliver, rxSkip uint64
	var wgAddr *net.UDPAddr
	var wgMu sync.Mutex
	// Initial hold 0, not HoldMin. The ratchet has observed nothing yet, so there
	// is nothing to hold FOR, and ring.go's own >=10ms floor (:148-153) is what
	// the Ring applies until the first observation. NAMED RISK: ring.go's warm-up
	// buffers for holdNow() before anchoring `next` to the minimum buffered seq
	// (:116-130), so a 10ms warm-up can orphan a slower path's opening window where
	// the old 150ms did not. That produces Olds, which is exactly the event the
	// ratchet learns from, so it is self-correcting -- but it is a real startup
	// cost and it is not measured on hardware.
	ring := NewRing(11, 0, func(b []byte) {
		atomicAdd(&rxDeliver, 1)
		wgMu.Lock()
		a := wgAddr
		wgMu.Unlock()
		if a != nil {
			wgSock.WriteToUDP(b, a)
		}
	})
	// U13 round 3: the ratchet is sized from the RING'S OWN mask, so it is built
	// after the Ring. Nothing between the two lines used it.
	ratchet := NewLatenessRatchet(ring.Mask())
	// Both hooks fire UNDER ring.mu. The ratchet takes only its own mutex and
	// calls nothing back into the Ring -- see hold.go's LOCK ORDER note.
	//
	// BOTH now carry the seq. OnOld is evidence only for a seq the ring GAVE UP
	// on: ring.go's flushTo advances the frontier past a window overflow without
	// skipping, and those arrivals used to raise H against an unrelated blockAt
	// (hold.go OnOld, ROUND 3).
	ring.OnSkip = func(seq uint32) {
		atomicAdd(&rxSkip, 1)
		ratchet.OnSkip(seq, time.Now())
	}
	ring.OnOld = func(seq, next uint32) { ratchet.OnOld(seq, time.Now()) }

	for i := 0; i < N; i++ {
		go func(p int) {
			buf := make([]byte, MaxFrame)
			for {
				n, _, err := pc[p].ReadFromUDP(buf)
				if err != nil {
					continue
				}
				fl, _, sq, ts, fseq, pay, e := Unpack(buf[:n])
				if e != nil {
					continue
				}
				core.Links[p].MarkRx()
				switch fl {
				case FlagPing:
					// The unmodified server still runs the push downlink and
					// needs its surface echoed back. Answer it verbatim.
					rxEst.Fold(p, float64(int32(stampMS()-ts)))
					qb, od, jt := rxEst.Echo(p)
					lp := byte(atomic.LoadUint32(&lossByte[p]))
					du := uint16(atomic.LoadUint64(&delivBytes[p]) / 256)
					pr := make([]byte, HdrLen+pongLen)
					pm := Pack(pr, FlagPong, byte(p), 0, ts, 0,
						[]byte{lp, qb, od, jt, byte(du >> 8), byte(du)})
					pc[p].WriteToUDP(pr[:pm], srv)
				case FlagPong:
					// Liveness only (MarkRx above). The pull core has no uplink
					// rate controller and no capacity estimate to feed.
				case FlagData:
					rxEst.Fold(p, float64(int32(stampMS()-ts)))
					owd.Sample(p, ts)
					// U13: the ring's horizon is the DERIVED hold. InstallOn
					// records what the Ring will actually use so OnSkip can
					// recover blockAt = t_skip - holdInForce (hold.go S3);
					// without it the observation degrades to a form MEASURED to
					// lose to the formula on every cell.
					//
					// ROUND 2: one call, not three. This used to be
					// Hold()/SetInForce()/ring.SetHold() under three separate
					// acquisitions from N concurrent RX goroutines, so a
					// goroutine holding a pre-Reset hold could re-install it
					// after the control goroutine had Reset the ratchet.
					// InstallOn makes record-and-install indivisible against
					// Reset.
					ratchet.InstallOn(ring.SetHold)
					// LossMeter's window is a RECEIVER late-attribution horizon
					// -- the same physical quantity as the ring hold -- so it
					// follows the ratchet, not the formula. EffHold, not Hold:
					// Hold() is 0 until the first OnOld, and a 0 horizon makes
					// the meter attribute every reorder immediately, which
					// OVER-REPORTS loss for the whole warm-up. EffHold is what
					// the RING is actually holding for (ring.go's own floor
					// applies below the first observation), so the meter and the
					// ring describe the same window at every instant.
					lossM[p].Data(fseq, time.Now(), ratchet.EffHold())
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
		pb := make([]byte, HdrLen)
		lastStat := time.Now()
		lastLoss := time.Now()
		alive := AliveSet(core)
		for {
			now := time.Now()
			for i := 0; i < N; i++ {
				m := Pack(pb, FlagPing, byte(i), 0, stampMS(), 0, nil)
				pc[i].WriteToUDP(pb[:m], srv)
				core.Links[i].SetAlive(core.Links[i].RxAge(now) <= DeadIval)
			}
			// U13: the reorder hold describes the DELIVERING SET, so a change in
			// that set invalidates every observation behind it. This is the
			// observable event the ratchet re-anchors on -- there is no decay
			// window, because no derivation for one exists. N-generic: a set
			// comparison, no index and no count assumed.
			if now2 := AliveSet(core); !SameAliveSet(alive, now2) {
				alive = now2
				// Reset re-anchors the RING in the same indivisible step (see
				// hold.go InstallOn / Reset): otherwise the ring would keep
				// holding for the old delivering set until the next arrival.
				ratchet.Reset(ring.SetHold)
				log.Printf("pull-hold: delivering set changed -> ratchet reset "+
					"(alive=%v); the learned hold described the old set", now2)
			}
			// hd is the SENDER-side pool residence budget and NOTHING ELSE now.
			hd := formulaHold(owd, HoldMin, HoldMax)
			ring.Tick(now)
			// Pool bound, AGE limb. Trim also INSTALLS hd on the pool so that
			// Enqueue and Return apply the same limb between ticks -- the bound
			// is no longer a 100 ms sampled thing (pull.go S5).
			//
			// S4, RESTATED AFTER U13 -- still OPEN, and now narrower.
			// hd is clamp(spread+3*jit+250, 150, 350) (hold.go formulaHold, copied
			// from paths.go:102), which is on the HANDOFF record as owed a
			// derivation. It governs SENDER-side residence by reusing a RECEIVER
			// reorder spread, and U13 does NOT close that: U13 derives the
			// RECEIVER hold, and a sender residence budget is a different physical
			// quantity with no derivation available (the correct one is a
			// residence-time budget over MEASURED aggregate delivered rate, which
			// is E1). What changed is that the ring no longer shares this number --
			// it runs on LatenessRatchet -- so this is now ONE formula with ONE
			// consumer, visible rather than hidden behind a shared variable.
			core.FIFO.Trim(now, hd)
			// Release drawers parked on an empty pool so a link that just went
			// dead (or came back) re-evaluates its own gate.
			core.FIFO.Wake()
			if now.Sub(lastLoss) >= LossIval {
				lastLoss = now
				// Receiver-side attribution horizon -> the ratchet, matching what
				// the ring is actually holding for. Not hd, which is the sender
				// residence budget. EffHold, not Hold: see the Data() call above
				// -- a 0 horizon before the first observation over-reports loss.
				rh := ratchet.EffHold()
				for i := 0; i < N; i++ {
					wl, wt := lossM[i].Window(now, rh)
					if wt > 0 {
						sLossE[i] = sLossE[i]*0.7 + (float64(wl)/float64(wt)*100.0)*0.3
					}
					lp := byte(min64(200, int64(sLossE[i]*2+0.5)))
					atomic.StoreUint32(&lossByte[i], uint32(lp))
				}
			}
			if now.Sub(lastStat) > time.Second {
				lastStat = now
				depth, peak, enq, drawn, stale := core.FIFO.Stats()
				qb, qbPeak, qbMax, qdrops, retq := core.FIFO.ByteStats()
				var sb strings.Builder
				// stale = shed by the AGE limb, qdrop = shed by the BYTE limb,
				// retq = backpressure rollbacks. Kept as three numbers: which
				// limb is shedding, and whether the links are refusing, are
				// different diagnoses and E1 reads them separately.
				// U13 counters. hold = what the ring is holding for RIGHT NOW: the
				// DERIVED hold, or ring.go's own 10ms floor before the first
				// observation. hpeak = the largest lateness ever observed, across
				// resets -- a G1/E1 input in its own right, since nobody has a
				// hardware measurement of how much reorder budget a real box
				// needs. hobs = frames that ARRIVED and were discarded anyway,
				// i.e. U11's late-discard, live. hrai = raises, hrst = resets.
				// sres = the SENDER residence budget: a DIFFERENT number for a
				// DIFFERENT quantity, printed separately because it is divergence
				// S4 and S4 is still open.
				_, rpk, rrai, robs, rrst := ratchet.Stats()
				fmt.Fprintf(&sb, "PSTAT n=%d depth=%d peak=%d qb=%d/%d peakb=%d enq=%d drawn=%d stale=%d qdrop=%d retq=%d hold=%dms hpeak=%dms hobs=%d hrai=%d hrst=%d sres=%dms del=%d skip=%d",
					core.N(), depth, peak, qb, qbMax, qbPeak, enq, drawn, stale, qdrops, retq,
					ring.HoldDur().Milliseconds(),
					rpk.Milliseconds(), robs, rrai, rrst, hd.Milliseconds(),
					atomic.LoadUint64(&rxDeliver), atomic.LoadUint64(&rxSkip))
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
				}
				log.Print(sb.String())
			}
			time.Sleep(PingIval)
		}
	}()

	core.Start()

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
