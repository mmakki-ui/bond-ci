package main

import (
	"log"
	"net"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// bond server daemon -- P5 / E3, the THIN, ISOLATED half of the pull datapath
// (docs/knowledge/design/p5-execution-handover.md section 3 E3, constraint C4).
//
// It does exactly four things:
//
// 1. Receives frames on ONE bonded-transport UDP port from N client links. N is
// discovered from the pathID byte on the wire; it is never configured.
//
// 2. Reorders the uplink by the global seq and writes each payload, unread and
// unmodified, to the local WireGuard endpoint.
//
// 3. Echoes, per link, a CUMULATIVE received frame/byte count plus a timestamp
// -- everything the client's delivered-rate meter needs and nothing more. The
// server computes no rate, keeps no window, and holds no ledger.
//
// 4. Returns WireGuard's replies to the client on the link the client itself
// most recently used.
//
// Everything else is client-side by construction: no per-flow state, no
// sub-packet reassembly, no cap, no duplication, no mode awareness. The server
// cannot tell which mode the client is running and never needs to.
//
// ISOLATION FROM OTHER WG PEERS (C4). This daemon opens exactly two sockets and
// touches nothing else -- no routes, no firewall rules, no sysctls, no wg
// interface, no privileged calls at all. The listener binds the bonded
// transport port (AGG_LISTEN), which is NOT a WireGuard listen port; binding it
// cannot affect any WireGuard socket. The forwarder is a CONNECTED UDP socket
// to the local WireGuard endpoint (AGG_WG), so the kernel accepts datagrams
// from that one address only, and every packet handed to WireGuard leaves from
// this daemon's own ephemeral port -- WireGuard sees one ordinary local peer
// endpoint, the bonded client's, and no other peer's session is observable or
// reachable from here. Replies only ever go to the source address of a frame
// just received on the bonded port: the daemon never initiates traffic and can
// never address a host it has not heard from. One instance serves one bonded
// client on one port; a second client is a second instance on a second port.

const (
	// RingPow2: 2^11 = 2048 resequencer slots, inherited from the client ring
	// (p4-bondagg/daemon/main.go, NewRing(11, ...)).
	RingPow2 = 11
	// TickIval services the resequencer gap timer. Inherited from the client's
	// PingIval cadence: the gap timer must be serviced at least that often for
	// a hold expiry to be noticed promptly.
	TickIval = 100 * time.Millisecond
	// StatIval is the SSTAT log period.
	StatIval = time.Second
)

// HoldMinDefault and HoldMaxDefault clamp the reorder horizon. Inherited
// VERBATIM from p4-bondagg/daemon/main.go (HoldMin/HoldMax) so both ends hold
// the same window by construction rather than by two independent guesses.
//
// FLAGGED, standing "no arbitrary constants" debt: these two are exactly the
// numbers HANDOFF.md calls out (paths.go:74, floor 150). They are inherited,
// not invented, and they move when the client's derived-hold work (U13 / OBJ-B)
// lands. The client's "+250ms" additive term is NOT inherited -- it paid for
// the EIF push estimator's probe queue, which the pull datapath deleted, so the
// horizon here is pure cross-link geometry (see OWD.Hold).
const (
	HoldMinDefault = 150 * time.Millisecond
	HoldMaxDefault = 350 * time.Millisecond
)

var (
	statBad       uint64
	statDnFrames  uint64
	statDnNoRoute uint64
	statEchoShed  uint64
	statEchoTrunc uint64
	statEchoTx    uint64
	statIgnored   uint64
	statToWG      uint64
	statWGErr     uint64
)

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func envMS(k string, d time.Duration) time.Duration {
	v := os.Getenv(k)
	if v == "" {
		return d
	}
	ms, err := strconv.Atoi(v)
	if err != nil || ms <= 0 {
		log.Printf("config: %s=%q ignored, keeping %v", k, v, d)
		return d
	}
	return time.Duration(ms) * time.Millisecond
}

// peers is the only address state the server keeps: one source address per
// link, plus the link the client most recently sent DATA on. Both are learned
// from DATA frames ONLY, so a stray or spoofed ping cannot move an endpoint or
// redirect the downlink. Nothing here is keyed on anything inside the payload
// -- the server has no idea what flows are inside the tunnel.
type peers struct {
	mu   sync.Mutex
	ep   [MaxLinks]*net.UDPAddr
	last byte
	have bool
}

func (p *peers) learn(link byte, a *net.UDPAddr) {
	p.mu.Lock()
	p.ep[link] = a
	p.last = link
	p.have = true
	p.mu.Unlock()
}

// route returns the link a downlink frame should ride: the one the client
// itself most recently drew on.
//
// This is deliberately not a scheduler. Under the pull datapath the client
// draws from its shared send-FIFO on every link that has room, so the arrival
// process on this port ALREADY IS the client's own capacity-proportional split;
// following it hands the downlink that split for free, with no weights, no
// quantum, no liveness timer and no constant of any kind. A link that stalls
// stops delivering uplink frames and therefore stops being chosen the moment
// any other link delivers -- failover with no failure detector. All the
// complexity stays client-side, which is the point of C4.
func (p *peers) route() (byte, *net.UDPAddr) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.have {
		return 0, nil
	}
	return p.last, p.ep[p.last]
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	listen := env("AGG_LISTEN", ":59402")
	wgStr := env("AGG_WG", "127.0.0.1:51820")
	holdMin := envMS("AGG_HOLD_MIN_MS", HoldMinDefault)
	holdMax := envMS("AGG_HOLD_MAX_MS", HoldMaxDefault)
	if holdMax < holdMin {
		log.Printf("config: AGG_HOLD_MAX_MS below AGG_HOLD_MIN_MS, clamping max to %v", holdMin)
		holdMax = holdMin
	}

	la, err := net.ResolveUDPAddr("udp4", listen)
	if err != nil {
		log.Fatal("resolve listen: ", err)
	}
	sock, err := net.ListenUDP("udp4", la)
	if err != nil {
		log.Fatal("listen: ", err)
	}
	wa, err := net.ResolveUDPAddr("udp4", wgStr)
	if err != nil {
		log.Fatal("resolve wg: ", err)
	}
	wgConn, err := net.DialUDP("udp4", nil, wa)
	if err != nil {
		log.Fatal("wg dial: ", err)
	}
	log.Printf("server: bonded %v -> wg %v (hold %v..%v; N discovered from the wire)",
		sock.LocalAddr(), wa, holdMin, holdMax)

	stats := &LinkStats{}
	bud := &echoBudget{}
	owd := &OWD{}
	pr := &peers{}

	ring := NewRing(RingPow2, holdMax, func(b []byte) {
		if _, werr := wgConn.Write(b); werr != nil {
			atomic.AddUint64(&statWGErr, 1)
			return
		}
		atomic.AddUint64(&statToWG, 1)
	})
	oldN := 0
	ring.OnOld = func(sq, nx uint32) {
		if oldN < 5 {
			oldN++
			log.Printf("OLDDROP seq=%d next=%d", sq, nx)
		}
	}

	var closing uint32
	sigc := make(chan os.Signal, 1)
	signal.Notify(sigc, os.Interrupt, syscall.SIGTERM)
	go func() {
		s := <-sigc
		log.Printf("shutdown on %v", s)
		atomic.StoreUint32(&closing, 1)
		sock.Close()
		wgConn.Close()
	}()

	// downlink: WireGuard's replies, framed and sent on the link the client
	// last used. No scheduling, no per-flow state -- see peers.route.
	go func() {
		buf := make([]byte, MaxPayload)
		out := make([]byte, MaxPayload+HdrLen)
		var dseq uint32
		for {
			n, rerr := wgConn.Read(buf)
			if rerr != nil {
				if atomic.LoadUint32(&closing) == 1 {
					return
				}
				continue
			}
			link, a := pr.route()
			if a == nil {
				atomic.AddUint64(&statDnNoRoute, 1)
				continue
			}
			m := Pack(out, FlagData, link, dseq, nowMS(), 0, buf[:n])
			dseq++
			if _, werr := sock.WriteToUDP(out[:m], a); werr != nil {
				if atomic.LoadUint32(&closing) == 1 {
					return
				}
				continue
			}
			atomic.AddUint64(&statDnFrames, 1)
		}
	}()

	// resequencer service + stats
	go func() {
		t := time.NewTicker(TickIval)
		defer t.Stop()
		last := time.Now()
		for now := range t.C {
			ring.Tick(now)
			if now.Sub(last) < StatIval {
				continue
			}
			last = now
			delivs, skips, olds, resyncs := ring.Counts()
			log.Printf("SSTAT del=%d towg=%d skip=%d old=%d resync=%d hold=%dms dn=%d dnnoroute=%d echo=%d echoshed=%d echotrunc=%d bad=%d ign=%d wgerr=%d",
				delivs, atomic.LoadUint64(&statToWG), skips, olds, resyncs,
				ring.HoldDur().Milliseconds(),
				atomic.LoadUint64(&statDnFrames), atomic.LoadUint64(&statDnNoRoute),
				atomic.LoadUint64(&statEchoTx), atomic.LoadUint64(&statEchoShed),
				atomic.LoadUint64(&statEchoTrunc), atomic.LoadUint64(&statBad),
				atomic.LoadUint64(&statIgnored), atomic.LoadUint64(&statWGErr))
		}
	}()

	// uplink RX -- the one hot loop
	buf := make([]byte, MaxFrame)
	echoPay := make([]byte, EchoMaxLen)
	echoOut := make([]byte, HdrLen+EchoMaxLen)
	for {
		n, ra, rerr := sock.ReadFromUDP(buf)
		if rerr != nil {
			if atomic.LoadUint32(&closing) == 1 {
				log.Printf("stopped")
				return
			}
			continue
		}
		fl, pid, sq, ts, _, pay, ferr := Unpack(buf[:n])
		if ferr != nil {
			atomic.AddUint64(&statBad, 1)
			continue
		}
		switch fl {
		case FlagData:
			if len(pay) == 0 {
				atomic.AddUint64(&statBad, 1)
				continue
			}
			// METER FIRST, at ARRIVAL, ahead of the ring. This is the oracle's
			// semantics verbatim (reserved_composite.py:414, "every arrival
			// turns the meter dial"): a duplicate seq counts and an arrival the
			// ring later discards as late counts, because the meter measures
			// what the LINK delivered, not what came out in order.
			stats.OnData(pid, n)
			bud.earn(n)
			pr.learn(pid, ra)
			owd.Sample(pid, ts)
			ring.SetHold(owd.Hold(holdMin, holdMax))
			ring.Push(sq, pay, time.Now())
		case FlagPing:
			// The echo is REQUEST-DRIVEN: reply on the link the ping arrived
			// on, to the ping's own source address, carrying every seen link's
			// cumulative counters and echoing the client's txstamp verbatim.
			// See the echo wire format in echo.go.
			pl := stats.Snapshot(echoPay, nowMS())
			m := Pack(echoOut, FlagEcho, pid, 0, ts, 0, echoPay[:pl])
			if !bud.spend(m) {
				atomic.AddUint64(&statEchoShed, 1)
				continue
			}
			if _, werr := sock.WriteToUDP(echoOut[:m], ra); werr != nil {
				if atomic.LoadUint32(&closing) == 1 {
					log.Printf("stopped")
					return
				}
				continue
			}
			atomic.AddUint64(&statEchoTx, 1)
		default:
			// FlagPong, FlagFEC, FlagEcho, anything else. This server never
			// asks the client a question, so it never expects a pong; the pull
			// datapath dropped FEC, so it never reconstructs parity; and it
			// never receives its own echo back. Counted, dropped, no state
			// touched.
			atomic.AddUint64(&statIgnored, 1)
		}
	}
}
