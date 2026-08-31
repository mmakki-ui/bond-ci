package main

import (
	"log"
	"net"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

const (
	HoldMin     = 150 * time.Millisecond
	HoldMax     = 350 * time.Millisecond
	PingIval    = 100 * time.Millisecond
	LossIval    = 500 * time.Millisecond
	SuspectIval = 300 * time.Millisecond
	// DeadIval: pong/frame age past which a path is declared DEAD (ineligible for
	// Pick + backup). Aligned to the FSM's validated DEAD_IVAL=600ms (nsched:368);
	// the prior 1500ms delayed failover ~900ms past the model's tuned point (#6).
	DeadIval = 600 * time.Millisecond
)

func main() {
	mode := env("AGG_MODE", "")
	switch mode {
	case "client":
		runClient()
	case "server":
		runServer()
	case "pull-client":
		// U7/E2a: the PULL core (pull.go + pullrun.go). Separate entry point so
		// the EIF push client above stays the default and is not regressed.
		runPullClient()
	default:
		log.Fatal("AGG_MODE=client|server|pull-client required")
	}
}

// pongLen is the R3 pong payload: [lp, qb, od, jt, dHi, dLo].
const pongLen = 6

// ---------------- client ----------------
func runClient() {
	listen := env("AGG_LISTEN", "127.0.0.1:59402")
	serverStr := env("AGG_SERVER", "")
	pathsStr := env("AGG_PATHS", "eth1,usb0")
	if serverStr == "" {
		log.Fatal("AGG_SERVER host:port required")
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
	N := len(devs)
	w := parseW(env("AGG_W", "20000,15000"), N)
	pc := make([]*net.UDPConn, N)
	for i := 0; i < N; i++ {
		pc[i], err = devConn(devs[i])
		if err != nil {
			log.Fatalf("path %s: %v", devs[i], err)
		}
	}
	log.Printf("client: %s -> %s via %v (N=%d)", listen, serverStr, devs, N)

	// ---- uplink SENDER stack ----
	est := make([]*Estr, N)
	capE := make([]*CapEst, N)
	ftx := make([]*FecTx, N)
	tc := make([]*tierCtl, N)
	for i := 0; i < N; i++ {
		est[i] = NewEstr()
		capE[i] = NewCapEst(w[i])
		ftx[i] = &FecTx{}
		tc[i] = &tierCtl{}
	}
	sched := NewSched(w)
	eif := NewEIF(est, capE, 0)
	// collapse -> CapEst cut + FEC collapse-coupling (K->8, weaken-freeze). Runs
	// under Sched.mu (from OnQ); touches CapEst/tierCtl/FecTx only, never re-enters
	// Sched. tierCtl.Collapse applies the K jump + feedforward atomically (TOCTOU).
	sched.OnCollapse = func(p int, postCutKb float64) {
		capE[p].OnCollapse(postCutKb)
		tc[p].Collapse(time.Now(), func(oldK, newK int) {
			ftx[p].SetK(newK)
			eif.OnTierChange(p, oldK, newK)
		})
	}

	// ---- downlink RECEIVER stack (client measures the server->client direction) ----
	rxEst := NewRxEstSet(make([]float64, N))
	owd := NewOWD(N)
	frx := make([]*FecRx, N)
	lossM := make([]*LossMeter, N)
	for i := 0; i < N; i++ {
		frx[i] = NewFecRx()
		lossM[i] = &LossMeter{}
	}
	sLossE := make([]float64, N)    // per-path loss EWMA (nsched _fec_report sLossE)
	delivBytes := make([]uint64, N) // downlink DATA bytes received (echoed in pong)
	lossByte := make([]uint32, N)   // downlink loss (0.5%-quantized), echoed in pong
	lossPeerB := make([]uint32, N)  // server-measured UPLINK loss (drives our tier)

	var rxDeliver, rxSkip uint64
	var wgAddr *net.UDPAddr
	var wgMu sync.Mutex
	ring := NewRing(11, 60*time.Millisecond, func(b []byte) {
		atomicAdd(&rxDeliver, 1)
		wgMu.Lock()
		a := wgAddr
		wgMu.Unlock()
		if a != nil {
			wgSock.WriteToUDP(b, a)
		}
	})
	ring.OnSkip = func(uint32) { atomicAdd(&rxSkip, 1) }

	lastRx := make([]int64, N) // unix ms, atomic
	for i := range lastRx {
		atomic.StoreInt64(&lastRx[i], time.Now().UnixMilli())
	}

	// per-path RX goroutines: downlink data -> ring/FEC/floor; pong -> uplink surface
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
				atomic.StoreInt64(&lastRx[p], time.Now().UnixMilli())
				switch fl {
				case FlagPing: // server's ping: fold for the downlink floor + reply
					rxEst.Fold(p, float64(int32(nowMS()-ts)))
					qb, od, jt := rxEst.Echo(p)
					lp := byte(atomic.LoadUint32(&lossByte[p]))
					du := uint16(atomic.LoadUint64(&delivBytes[p]) / 256)
					pr := make([]byte, HdrLen+pongLen)
					pm := Pack(pr, FlagPong, byte(p), 0, ts, 0, []byte{lp, qb, od, jt, byte(du >> 8), byte(du)})
					pc[p].WriteToUDP(pr[:pm], srv)
				case FlagPong: // server's pong: our UPLINK surface (server-measured)
					if len(pay) >= pongLen {
						sched.OnQ(p, float64(pay[1])*QMEAS_QUANT) // AIMD (uplink q)
						du := uint16(pay[4])<<8 | uint16(pay[5])
						est[p].OnPong(time.Now(), float64(pay[1])*QMEAS_QUANT,
							float64(pay[2])*OD_QUANT, float64(pay[3]), du)
						atomic.StoreUint32(&lossPeerB[p], uint32(pay[0]))
					}
				case FlagFEC: // downlink parity
					if rs, rd, ok := frx[p].Parity(sq, int(buf[3]), pay); ok {
						ring.Push(rs, rd, time.Now())
					}
				case FlagData: // downlink data
					rxEst.Fold(p, float64(int32(nowMS()-ts)))
					owd.Sample(p, ts)
					hd := owd.Hold(HoldMin, HoldMax)
					ring.SetHold(hd) // #7: race-free (was a bare field write vs locked read)
					lossM[p].Data(fseq, time.Now(), hd)
					atomic.AddUint64(&delivBytes[p], uint64(n))
					if rs, rd, ok := frx[p].Data(fseq, sq, pay); ok {
						ring.Push(rs, rd, time.Now())
					}
					ring.Push(sq, pay, time.Now())
				}
			}
		}(i)
	}

	// pings + liveness + ring tick + CapEst report + FSM + loss/tier epoch
	go func() {
		pb := make([]byte, HdrLen)
		lastStat := time.Now()
		lastLoss := time.Now()
		for {
			for i := 0; i < N; i++ {
				n := Pack(pb, FlagPing, byte(i), 0, nowMS(), 0, nil)
				pc[i].WriteToUDP(pb[:n], srv)
				age := time.Duration(time.Now().UnixMilli()-atomic.LoadInt64(&lastRx[i])) * time.Millisecond
				eif.SetAlive(i, age <= DeadIval)
			}
			sched.TickIncrease()
			now := time.Now()
			for i := 0; i < N; i++ {
				// #3: thread `heard` (a fresh pong this window) into CapEst so a
				// pong-less window can't fold a 0-diff delivRate and crash chat.
				snap, heard := est[i].Report(now)
				capE[i].Report(snap, heard)
			}
			eif.Control(now)
			ring.Tick(now)
			if time.Since(lastLoss) >= LossIval {
				lastLoss = time.Now()
				for i := 0; i < N; i++ {
					// downlink loss we measured (echoed to server for its tier).
					// nsched _fec_report: use the reorder-IMMUNE FEC-group ledger
					// (frx.TakeRaw, 600ms age-retire) when armed; else the reorder-
					// tolerant per-path LossMeter (K=0 ring-skip fallback). One EWMA.
					rl, rs := frx[i].TakeRaw(now)
					// drain/reset the K=0 meter at the current owd horizon
					wl, wt := lossM[i].Window(now, owd.Hold(HoldMin, HoldMax))
					if rs > 0 {
						sLossE[i] = sLossE[i]*0.7 + (float64(rl)/float64(rs)*100.0)*0.3
					} else if wt > 0 {
						sLossE[i] = sLossE[i]*0.7 + (float64(wl)/float64(wt)*100.0)*0.3
					}
					lp := byte(min64(200, int64(sLossE[i]*2+0.5)))
					atomic.StoreUint32(&lossByte[i], uint32(lp))
					// uplink tier step from the server-reported loss (R1: at the
					// loss epoch, not per pong; TOCTOU-safe apply under tierCtl.mu)
					lossPct := float64(atomic.LoadUint32(&lossPeerB[i])) / 2.0
					tc[i].StepHyst(time.Now(), lossPct, func(oldK, newK int) {
						ftx[i].SetK(newK)
						eif.OnTierChange(i, oldK, newK)
					})
				}
			}
			if time.Since(lastStat) > time.Second {
				lastStat = time.Now()
				rates, q := sched.Rates()
				log.Printf("STAT prim=%d rate0=%.0f q0=%.0f chat0=%.0f K0=%d txdrop=%d peerloss=%.1f%%",
					eif.Prim(), rates[0], q[0], capE[0].Chat(), eif.kOf(0), eif.TxDrops(),
					float64(atomic.LoadUint32(&lossPeerB[0]))/2.0)
			}
			time.Sleep(PingIval)
		}
	}()

	// WG -> EIF -> uplink paths
	buf := make([]byte, MaxPayload)
	out := make([]byte, MaxPayload+HdrLen)
	fseqUp := make([]uint32, N)
	var seq uint32
	sendData := func(p int, gseq uint32, payload []byte) {
		fs := fseqUp[p]
		fseqUp[p]++
		m := Pack(out, FlagData, byte(p), gseq, nowMS(), fs, payload)
		pc[p].WriteToUDP(out[:m], srv)
		est[p].OnSend(m)
		if pp, ps, kk := ftx[p].Add(gseq, fs, payload); pp != nil {
			if eif.AdmitParity(p, len(pp)+HdrLen) { // R2: drop parity if backpressured
				fout := make([]byte, len(pp)+HdrLen) // parity carries a 6B seqXOR+xlen prefix
				fm := Pack(fout, FlagFEC, byte(p), ps, nowMS(), 0, pp)
				fout[3] = kk
				pc[p].WriteToUDP(fout[:fm], srv)
				est[p].OnSend(fm)
			}
		}
	}
	for {
		n, ra, err := wgSock.ReadFromUDP(buf)
		if err != nil {
			continue
		}
		wgMu.Lock()
		wgAddr = ra
		wgMu.Unlock()
		p := eif.Pick(n + HdrLen)
		if p < 0 {
			continue // txdrop (backpressure / no eligible path); accounted in EIF
		}
		gseq := seq
		seq++
		sendData(p, gseq, buf[:n])
		// suspect window: duplicate onto the best-ETA backup path (receiver dedups)
		pAge := time.Duration(time.Now().UnixMilli()-atomic.LoadInt64(&lastRx[p])) * time.Millisecond
		if pAge > SuspectIval {
			if b := eif.Backup(p, n+HdrLen); b >= 0 {
				oAge := time.Duration(time.Now().UnixMilli()-atomic.LoadInt64(&lastRx[b])) * time.Millisecond
				if oAge <= DeadIval {
					sendData(b, gseq, buf[:n])
				}
			}
		}
	}
}

// ---------------- server ----------------
func runServer() {
	listen := env("AGG_LISTEN", ":59402")
	wgStr := env("AGG_WG", "127.0.0.1:51820")
	pathsN := env("AGG_PATHS", "eth1,usb0")
	la, _ := net.ResolveUDPAddr("udp4", listen)
	sock, err := net.ListenUDP("udp4", la)
	if err != nil {
		log.Fatal("listen: ", err)
	}
	wgAddr, _ := net.ResolveUDPAddr("udp4", wgStr)
	wgConn, err := net.DialUDP("udp4", nil, wgAddr)
	if err != nil {
		log.Fatal("wg dial: ", err)
	}
	N := len(strings.Split(pathsN, ","))
	w := parseW(env("AGG_W", "20000,15000"), N)
	log.Printf("server: %s -> %s (N=%d)", listen, wgStr, N)

	// ---- downlink SENDER stack (server->client) ----
	est := make([]*Estr, N)
	capE := make([]*CapEst, N)
	ftx := make([]*FecTx, N)
	tc := make([]*tierCtl, N)
	for i := 0; i < N; i++ {
		est[i] = NewEstr()
		capE[i] = NewCapEst(w[i])
		ftx[i] = &FecTx{}
		tc[i] = &tierCtl{}
	}
	sched := NewSched(w)
	eif := NewEIF(est, capE, 0)
	sched.OnCollapse = func(p int, postCutKb float64) {
		capE[p].OnCollapse(postCutKb)
		tc[p].Collapse(time.Now(), func(oldK, newK int) {
			ftx[p].SetK(newK)
			eif.OnTierChange(p, oldK, newK)
		})
	}

	// ---- uplink RECEIVER stack (server measures the client->server direction) ----
	rxEst := NewRxEstSet(make([]float64, N))
	owd := NewOWD(N)
	frx := make([]*FecRx, N)
	lossM := make([]*LossMeter, N)
	for i := 0; i < N; i++ {
		frx[i] = NewFecRx()
		lossM[i] = &LossMeter{}
	}
	sLossE := make([]float64, N) // per-path loss EWMA (nsched _fec_report sLossE)
	delivBytes := make([]uint64, N)
	lossByte := make([]uint32, N)  // uplink loss we measured (echoed to client)
	lossPeerB := make([]uint32, N) // client-measured DOWNLINK loss (drives our tier)

	var rxDeliver, rxSkip uint64
	eps := make([]*net.UDPAddr, N)
	var epMu sync.Mutex
	lastRx := make([]int64, N)
	for i := range lastRx {
		atomic.StoreInt64(&lastRx[i], time.Now().UnixMilli())
	}
	ring := NewRing(11, 60*time.Millisecond, func(b []byte) { atomicAdd(&rxDeliver, 1); wgConn.Write(b) })
	ring.OnSkip = func(uint32) { atomicAdd(&rxSkip, 1) }
	// #7: install OnOld BEFORE any RX goroutine can Push (Push reads r.OnOld under
	// r.mu). Was set inside the report goroutine, racing the uplink RX loop.
	oldN := 0
	ring.OnOld = func(sq, nx uint32) {
		if oldN < 5 {
			oldN++
			log.Printf("OLDDROP seq=%d next=%d", sq, nx)
		}
	}

	// downlink: WG replies -> EIF -> client path endpoints
	go func() {
		buf := make([]byte, MaxPayload)
		out := make([]byte, MaxPayload+HdrLen)
		fseqDn := make([]uint32, N)
		var seq uint32
		sendData := func(p int, gseq uint32, payload []byte) bool {
			epMu.Lock()
			a := eps[p]
			epMu.Unlock()
			if a == nil {
				return false
			}
			fs := fseqDn[p]
			fseqDn[p]++
			m := Pack(out, FlagData, byte(p), gseq, nowMS(), fs, payload)
			sock.WriteToUDP(out[:m], a)
			est[p].OnSend(m)
			if pp, ps, kk := ftx[p].Add(gseq, fs, payload); pp != nil {
				if eif.AdmitParity(p, len(pp)+HdrLen) { // R2
					fout := make([]byte, len(pp)+HdrLen) // parity carries a 6B prefix
					fm := Pack(fout, FlagFEC, byte(p), ps, nowMS(), 0, pp)
					fout[3] = kk
					sock.WriteToUDP(fout[:fm], a)
					est[p].OnSend(fm)
				}
			}
			return true
		}
		for {
			n, err := wgConn.Read(buf)
			if err != nil {
				continue
			}
			p := eif.Pick(n + HdrLen)
			if p < 0 {
				continue
			}
			gseq := seq
			seq++
			if !sendData(p, gseq, buf[:n]) {
				// primary endpoint unknown: fall back to any known backup
				if b := eif.Backup(p, n+HdrLen); b >= 0 {
					sendData(b, gseq, buf[:n])
				}
				continue
			}
			pAge := time.Duration(time.Now().UnixMilli()-atomic.LoadInt64(&lastRx[p])) * time.Millisecond
			if pAge > SuspectIval {
				if b := eif.Backup(p, n+HdrLen); b >= 0 {
					oAge := time.Duration(time.Now().UnixMilli()-atomic.LoadInt64(&lastRx[b])) * time.Millisecond
					if oAge <= DeadIval {
						sendData(b, gseq, buf[:n])
					}
				}
			}
		}
	}()

	// liveness sweeper + server->client pings + report loop + loss/tier epoch
	go func() {
		pb := make([]byte, HdrLen)
		lastStat := time.Now()
		lastLoss := time.Now()
		for {
			epMu.Lock()
			addrs := make([]*net.UDPAddr, N)
			copy(addrs, eps)
			epMu.Unlock()
			for i := 0; i < N; i++ {
				if addrs[i] != nil {
					n := Pack(pb, FlagPing, byte(i), 0, nowMS(), 0, nil)
					sock.WriteToUDP(pb[:n], addrs[i])
				}
				age := time.Duration(time.Now().UnixMilli()-atomic.LoadInt64(&lastRx[i])) * time.Millisecond
				eif.SetAlive(i, age <= DeadIval)
			}
			sched.TickIncrease()
			now := time.Now()
			for i := 0; i < N; i++ {
				// #3: thread `heard` (a fresh pong this window) into CapEst so a
				// pong-less window can't fold a 0-diff delivRate and crash chat.
				snap, heard := est[i].Report(now)
				capE[i].Report(snap, heard)
			}
			eif.Control(now)
			ring.Tick(now)
			if time.Since(lastLoss) >= LossIval {
				lastLoss = time.Now()
				for i := 0; i < N; i++ {
					// uplink loss we measured (echoed to client). nsched _fec_report:
					// reorder-IMMUNE FEC-group ledger when armed; reorder-tolerant
					// LossMeter (K=0 ring-skip fallback) otherwise. One EWMA.
					rl, rs := frx[i].TakeRaw(now)
					// drain/reset the K=0 meter at the current owd horizon
					wl, wt := lossM[i].Window(now, owd.Hold(HoldMin, HoldMax))
					if rs > 0 {
						sLossE[i] = sLossE[i]*0.7 + (float64(rl)/float64(rs)*100.0)*0.3
					} else if wt > 0 {
						sLossE[i] = sLossE[i]*0.7 + (float64(wl)/float64(wt)*100.0)*0.3
					}
					lp := byte(min64(200, int64(sLossE[i]*2+0.5)))
					atomic.StoreUint32(&lossByte[i], uint32(lp))
					lossPct := float64(atomic.LoadUint32(&lossPeerB[i])) / 2.0
					tc[i].StepHyst(time.Now(), lossPct, func(oldK, newK int) {
						ftx[i].SetK(newK)
						eif.OnTierChange(i, oldK, newK)
					})
				}
			}
			if time.Since(lastStat) > time.Second {
				lastStat = time.Now()
				log.Printf("SSTAT del=%d skip=%d old=%d hold=%dms prim=%d chat0=%.0f K0=%d txdrop=%d peerloss=%.1f%%",
					ring.Delivs, ring.Skips, ring.Olds, ring.HoldDur().Milliseconds(),
					eif.Prim(), capE[0].Chat(), eif.kOf(0), eif.TxDrops(),
					float64(atomic.LoadUint32(&lossPeerB[0]))/2.0)
			}
			time.Sleep(PingIval)
		}
	}()

	// uplink: client -> server
	buf := make([]byte, MaxFrame)
	for {
		n, ra, err := sock.ReadFromUDP(buf)
		if err != nil {
			continue
		}
		fl, pid, sq, ts, fseq, pay, e := Unpack(buf[:n])
		if e != nil || int(pid) >= N {
			continue
		}
		p := int(pid)
		epMu.Lock()
		eps[p] = ra
		epMu.Unlock()
		atomic.StoreInt64(&lastRx[p], time.Now().UnixMilli())
		switch fl {
		case FlagPing: // client's ping: fold for the uplink floor + reply w/ surface
			rxEst.Fold(p, float64(int32(nowMS()-ts)))
			qb, od, jt := rxEst.Echo(p)
			lp := byte(atomic.LoadUint32(&lossByte[p]))
			du := uint16(atomic.LoadUint64(&delivBytes[p]) / 256)
			pong := make([]byte, HdrLen+pongLen)
			m := Pack(pong, FlagPong, byte(p), 0, ts, 0, []byte{lp, qb, od, jt, byte(du >> 8), byte(du)})
			sock.WriteToUDP(pong[:m], ra)
		case FlagPong: // client's pong: our DOWNLINK surface (client-measured)
			if len(pay) >= pongLen {
				sched.OnQ(p, float64(pay[1])*QMEAS_QUANT)
				du := uint16(pay[4])<<8 | uint16(pay[5])
				est[p].OnPong(time.Now(), float64(pay[1])*QMEAS_QUANT,
					float64(pay[2])*OD_QUANT, float64(pay[3]), du)
				atomic.StoreUint32(&lossPeerB[p], uint32(pay[0]))
			}
		case FlagFEC: // uplink parity
			if rs, rd, ok := frx[p].Parity(sq, int(buf[3]), pay); ok {
				ring.Push(rs, rd, time.Now())
			}
		case FlagData: // uplink data
			rxEst.Fold(p, float64(int32(nowMS()-ts)))
			owd.Sample(p, ts)
			hd := owd.Hold(HoldMin, HoldMax)
			ring.SetHold(hd) // #7: race-free (was a bare field write vs locked read)
			lossM[p].Data(fseq, time.Now(), hd)
			atomic.AddUint64(&delivBytes[p], uint64(n))
			if rs, rd, ok := frx[p].Data(fseq, sq, pay); ok {
				ring.Push(rs, rd, time.Now())
			}
			ring.Push(sq, pay, time.Now())
		}
	}
}

// parseW parses an N-CSV of per-path weight floors (kb/s); missing/garbage
// entries default to 10000.
func parseW(s string, n int) []float64 {
	parts := strings.Split(s, ",")
	w := make([]float64, n)
	for i := 0; i < n; i++ {
		w[i] = 10000
		if i < len(parts) {
			var x int
			if _, err := fmtSscan(parts[i], &x); err == nil && x > 0 {
				w[i] = float64(x)
			}
		}
	}
	return w
}
