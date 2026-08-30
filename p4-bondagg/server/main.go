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
	statEchoNoEp  uint64
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

// peers is the only address state the server keeps: one source address per link
// (ep), plus the link the client most recently sent DATA on (last, the downlink
// route). Nothing here is keyed on anything inside the payload -- the server has
// no idea what flows are inside the tunnel.
//
// WHAT MOVES WHICH, precisely, because the two fields have DIFFERENT rules and
// an earlier version of this comment claimed one rule for both:
//
//   - last (the ROUTE) moves on accepted DATA frames only. No ping of any kind,
//     authenticated or not, can redirect the downlink. Pinned by
//     TestAuthenticatedPingRefreshesTheEndpointNotTheRoute.
//   - ep (the ENDPOINT the echo is sent to) moves on accepted DATA frames AND on
//     an AUTHENTICATED ping, via learnEp (rx.go), so that a NAT rebinding
//     between two data frames does not leave the echo aimed at a dead address.
//
// "Accepted" is the whole qualification. With the auth gate CLOSED, accepted
// means tagged, and a forged frame moves neither field. With the gate OPEN --
// which is the posture of every install today, see server/auth.go -- accepted
// means well-formed, so ONE forged DATA frame moves BOTH: it redirects the
// downlink and it installs the attacker's chosen address as the link's echo
// endpoint. Pinned in both directions by the positive controls in
// auth_vectors_test.go.
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

// learnEp updates a link's endpoint WITHOUT touching the downlink route. Called
// only for an AUTHENTICATED ping (rx.go), so that a NAT rebinding between two
// data frames does not send the echo to a dead address, while the route itself
// stays a DATA-only decision. Pinned by
// TestAuthenticatedPingRefreshesTheEndpointNotTheRoute.
func (p *peers) learnEp(link byte, a *net.UDPAddr) {
	p.mu.Lock()
	p.ep[link] = a
	p.mu.Unlock()
}

// endpoint returns the address last learned for one link, or nil if this server
// has never accepted a frame on it.
func (p *peers) endpoint(link byte) *net.UDPAddr {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.ep[link]
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

	// FRAMING AUTHENTICATION. A missing or unusable key file is NOT fatal: this
	// box has no console (HANDOFF section 0a), so a daemon that refuses to start
	// over a config file is a way to lose it. It logs loudly and runs exactly as
	// it did before U31 -- see the authGate comment for the full degradation
	// argument.
	keyPath := env("AGG_KEY_FILE", KeyFileDefault)
	keys, kerr := LoadKeys(keyPath)
	if kerr != nil {
		log.Printf("auth: cannot read %s (%v)", keyPath, kerr)
	}
	gate := newAuthGate(keys, clampReopen(envMS("AGG_AUTH_REOPEN_MS", ReopenDefault)), roleServer)
	if gate.Enabled() {
		log.Printf("auth: %d key(s) from %s, reopen horizon %v", len(keys), keyPath, gate.reopen)
	} else {
		log.Printf("auth: OFF -- no usable key in %s. Every well-formed frame from every "+
			"source is accepted, which is the pre-U31 posture: one forged frame can move "+
			"the downlink and one forged seq can cost a hold of uplink", keyPath)
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
		out := make([]byte, HdrLen+MaxPayload+MacLen)
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
			if sm := gate.Seal(out, m, time.Now()); sm < 0 {
				// out is HdrLen+MaxPayload+MacLen, so this cannot fire unless
				// someone resizes it. Drop rather than emit FlagAuth with no
				// tag, which the client would shed as a forgery. Counted inside
				// the gate (SealShort, in the SSTAT line below); there are only
				// two Seal call sites in this module, so one counter attributes
				// it well enough.
				continue
			} else {
				m = sm
			}
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
			aok, abad, ashed := gate.Counts()
			shut := 0
			if gate.Closed(now) {
				shut = 1
			}
			log.Printf("SSTAT del=%d towg=%d skip=%d old=%d resync=%d hold=%dms dn=%d dnnoroute=%d echo=%d echoshed=%d echonoep=%d echotrunc=%d bad=%d ign=%d wgerr=%d authok=%d authbad=%d authshed=%d sealshort=%d gate=%d",
				delivs, atomic.LoadUint64(&statToWG), skips, olds, resyncs,
				ring.HoldDur().Milliseconds(),
				atomic.LoadUint64(&statDnFrames), atomic.LoadUint64(&statDnNoRoute),
				atomic.LoadUint64(&statEchoTx), atomic.LoadUint64(&statEchoShed),
				atomic.LoadUint64(&statEchoNoEp),
				atomic.LoadUint64(&statEchoTrunc), atomic.LoadUint64(&statBad),
				atomic.LoadUint64(&statIgnored), atomic.LoadUint64(&statWGErr),
				aok, abad, ashed,
				gate.SealShort(), shut)
		}
	}()

	// uplink RX -- the one hot loop. Every per-frame decision lives in
	// rxPath.Handle (rx.go) so it can be driven by a test with no socket; this
	// loop is now read, hand over, write.
	//
	// The buffer is MaxAuthFrame, not MaxFrame: an authenticated frame carries
	// MacLen trailing bytes. Reading a full frame into a buffer MacLen too short
	// silently truncates it, which would look exactly like a bad tag.
	rx := newRxPath(gate, pr, stats, bud, owd, ring, holdMin, holdMax)
	buf := make([]byte, MaxAuthFrame)
	for {
		n, ra, rerr := sock.ReadFromUDP(buf)
		if rerr != nil {
			if atomic.LoadUint32(&closing) == 1 {
				log.Printf("stopped")
				return
			}
			continue
		}
		out, dst := rx.Handle(buf[:n], ra, time.Now())
		if out == nil {
			continue
		}
		if _, werr := sock.WriteToUDP(out, dst); werr != nil {
			if atomic.LoadUint32(&closing) == 1 {
				log.Printf("stopped")
				return
			}
			continue
		}
	}
}
