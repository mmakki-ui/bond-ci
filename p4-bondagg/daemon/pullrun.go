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
//     side pool residence budget (core.FIFO.Trim). Same number, different
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
		log.Printf("pull-pool: maxq=%d bytes (%s); age limb = owd.Hold(%v,%v) -- see "+
			"pull.go S3/S4, both limbs are OPEN divergences from the oracle",
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

	// ---- E2b: the delivered-rate CAP. OFF by default (cap.go) ----------------
	//
	// Enablement is E1's decision (p5-execution-handover.md:85, ROADMAP.md:193),
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

	// ---- receive side: downlink -> reorder ring -> WG ----
	owd := NewOWD(N)
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

	for i := 0; i < N; i++ {
		go func(p int) {
			buf := make([]byte, MaxFrame)
			// Reused across echoes so the receive path allocates nothing per
			// frame. Only meaningful while the cap is on; FoldEcho is a
			// nil-receiver no-op otherwise.
			bpress := make([]uint64, N)
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
					rxEst.Fold(p, float64(int32(nowMS()-ts)))
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
		pb := make([]byte, HdrLen)
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
				m := Pack(pb, FlagPing, byte(i), 0, ts, 0, nil)
				pc[i].WriteToUDP(pb[:m], srv)
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
			core.FIFO.Trim(now, hd)
			// Release drawers parked on an empty pool so a link that just went
			// dead (or came back) re-evaluates its own gate.
			core.FIFO.Wake()
			if now.Sub(lastLoss) >= LossIval {
				lastLoss = now
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
				depth, peak, enq, drawn, stale := core.FIFO.Stats()
				qb, qbPeak, qbMax, qdrops, retq := core.FIFO.ByteStats()
				var sb strings.Builder
				// stale = shed by the AGE limb, qdrop = shed by the BYTE limb,
				// retq = backpressure rollbacks. Kept as three numbers: which
				// limb is shedding, and whether the links are refusing, are
				// different diagnoses and E1 reads them separately.
				fmt.Fprintf(&sb, "PSTAT n=%d depth=%d peak=%d qb=%d/%d peakb=%d enq=%d drawn=%d stale=%d qdrop=%d retq=%d hold=%dms del=%d skip=%d",
					core.N(), depth, peak, qb, qbMax, qbPeak, enq, drawn, stale, qdrops, retq,
					ring.HoldDur().Milliseconds(),
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
					// E2b, printed only when the cap is ON so the OFF line is
					// byte-identical to U7's. cap=1/0 is the latch; far is the
					// estimated far-inflight time the bound compares against
					// target; unal counts echoes that matched NO ping marker,
					// which is the alignment failing and is the number to read
					// first if the cap misbehaves; rb counts server restarts
					// (counter regressions) plus the one first-reading baseline.
					//
					// span/mk/INERT are the marker ring making itself legible.
					// span is the MEASURED ping->echo round trip in the client's
					// own clock and mk is the ring depth derived from it
					// (cap.go, THE MARKER RING). INERT means echoes arrived and
					// not one ever folded, i.e. the cap is on and measuring
					// nothing -- the round-1 defect, which was silent. Read
					// INERT before anything else on this line.
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
