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
	// StatIval is the SSTAT sampling cadence: how often the goroutine checks
	// whether a line is due. It is NOT the emit period any more -- see
	// StatHeartbeat and statDecision.
	StatIval = time.Second
	// StatHeartbeat bounds how long an idle server can stay silent. With no
	// counter change and no gate transition, one SSTAT line still goes out
	// at least this often so the box proves it is alive. Chosen well above
	// StatIval so a quiet link costs one line a minute, not one a second,
	// into the shared logd ring that dropbear/wg also write to
	// (init.d/p5-server routes stderr there; U132).
	StatHeartbeat = 60 * time.Second
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

// statSnapshot is every field the SSTAT line reports, at one instant. Two
// snapshots compare equal with == iff the line they would render is
// identical, so "did anything worth logging change" is just cur != prev --
// no field-by-field diff to keep in sync with the log format by hand.
// gateShut is in here too (not carried alongside as a separate flag), which
// is what makes a gate= transition fall out of the same comparison as every
// other counter instead of needing its own case.
type statSnapshot struct {
	delivs, towg, skip, old, resync     uint64
	holdMS                              int64
	dn, dnnoroute                       uint64
	echo, echoshed, echonoep, echotrunc uint64
	bad, ign, wgerr                     uint64
	authok, authbad, authshed           uint64
	sealshort                           uint64
	gateShut                            int
}

// statDecision reports whether the stat goroutine should emit an SSTAT line
// this tick. It takes no socket, no ticker and no package state -- every
// input is a parameter -- so it is testable as a plain table:
//
//   - first is true only until the first line has ever gone out: that line
//     always emits, so a server that just started always says so.
//   - cur is this tick's snapshot, prev is the snapshot as of the last
//     EMITTED line (not the last tick). cur != prev covers both "some
//     counter moved since we last spoke" and "the gate= field flipped",
//     since gateShut is one of the compared fields.
//   - sinceLast is how long it has been since the last emitted line; past
//     StatHeartbeat with nothing else to report, one heartbeat line still
//     goes out so an idle server keeps proving it is alive without paying
//     the old per-second cost into the shared logd ring (U132).
func statDecision(cur, prev statSnapshot, first bool, sinceLast time.Duration) bool {
	if first {
		return true
	}
	if cur != prev {
		return true
	}
	return sinceLast >= StatHeartbeat
}

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
//   - hint (U34a) is the DELTA the last accepted DATA frame carried in header
//     byte [3]. It moves on accepted DATA frames, with last, and it moves
//     NEITHER ep NOR last itself: it is read once per downlink frame by route,
//     the only place it can change anything.
//   - seen is when each link's ep was last written, by either writer. It exists
//     only to bound how stale a HINTED endpoint may be -- see EpMaxAge.
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
	seen [MaxLinks]time.Time
	last byte
	hint byte
	have bool
}

// EpMaxAge bounds how stale a HINTED link's endpoint may be before route falls
// back to A0. It applies ONLY to a hint target, never to the frame's own path.
//
// WHY IT EXISTS (U34a spec item 6 / the review's BL4). Under the pre-U34a rule
// `last` and `ep[last]` were written by the same frame, in one learn call under
// one mutex, so the address the downlink used was at most one uplink packet old
// BY CONSTRUCTION. A hint breaks that pairing on purpose: the whole point is to
// route downlink onto a link the client is deliberately NOT sending DATA on, and
// ep for that link was last written whenever DATA last arrived from it -- which
// may be long ago, or never. Without a bound, a hint can aim the downlink at an
// address nothing has re-confirmed, with no error and no counter: strictly worse
// than the rule it replaces, at the one thing that rule got right for free.
//
// DERIVED, not chosen, and it is the same derivation as ReopenFloor
// (auth.go): the peer's own liveness timer is DeadIval = 600 ms
// (daemon/main.go:29). A link a HEALTHY tunnel is keeping alive has sent
// something inside that window, so an endpoint older than it belongs to a link
// the client itself would already call dead. Like ReopenFloor this is a
// hand-kept mirror of a constant in the other module, not an import; if DeadIval
// moves, this moves with it. Pinned by TestEpMaxAgeMatchesPeerLiveness.
//
// WHAT REFRESHES seen[], and the honest consequence. Both writers of ep write it
// (learn on an accepted DATA frame, learnEp on an AUTHENTICATED ping, which the
// pull client emits per link every PingIval = 100 ms). So with the auth gate
// CLOSED -- the posture a hinting install is meant to run in -- every live link
// is refreshed six times per horizon whether or not it carries DATA. With the
// gate OPEN, which is every install today (auth.go), nothing but DATA refreshes
// it, because letting an unauthenticated ping install an endpoint is U31's
// reflection vector and is not reopened here. So on a keyless install a hint
// toward a DATA-silent link expires after 600 ms and the downlink falls back to
// the frame's own path. That is the intended failure: never a blackhole, never a
// fixed index, never worse than A0.
const EpMaxAge = 600 * time.Millisecond

// learn records an accepted DATA frame: the link's source address, the link as
// the downlink route, and the downlink HINT that frame carried (U34a). hint is
// header byte [3] under FlagData and NOTHING ELSE -- rx.go reads it only in the
// FlagData arm, so the byte's FlagFEC meaning (K) can never reach here.
//
// The hint deliberately does NOT move `last`: `last` keeps meaning "the link the
// client most recently sent DATA on", which is what the U31 vector-1 test
// asserts and what the fallback needs to be correct. Resolving the target is
// route's job, once per downlink frame, so a hint toward a link that goes stale
// between two frames stops being followed at the next frame rather than being
// latched at learn time.
func (p *peers) learn(link, hint byte, a *net.UDPAddr, now time.Time) {
	p.mu.Lock()
	p.ep[link] = a
	p.seen[link] = now
	p.last = link
	p.hint = hint
	p.have = true
	p.mu.Unlock()
}

// learnEp updates a link's endpoint WITHOUT touching the downlink route. Called
// only for an AUTHENTICATED ping (rx.go), so that a NAT rebinding between two
// data frames does not send the echo to a dead address, while the route itself
// stays a DATA-only decision. Pinned by
// TestAuthenticatedPingRefreshesTheEndpointNotTheRoute.
//
// It also stamps seen[], which is what keeps a hinted-but-DATA-silent link
// eligible under EpMaxAge while the gate is closed.
func (p *peers) learnEp(link byte, a *net.UDPAddr, now time.Time) {
	p.mu.Lock()
	p.ep[link] = a
	p.seen[link] = now
	p.mu.Unlock()
}

// liveLinks counts the pathIDs whose endpoint was refreshed within EpMaxAge --
// the server's whole notion of "how many paths is this client actually using
// right now". It reads the SAME seen[] table and the SAME horizon the downlink
// hint already ages against (routeAt, above): a path the client has not been
// heard from inside EpMaxAge is one the client itself would already call dead,
// which is precisely the derivation EpMaxAge documents. No new constant, no new
// state, no mode awareness -- the count is a property of the wire.
//
// The IsZero() guard is a belt: for any clock this daemon can actually see,
// now.Sub(zeroTime) is ~2000 years and the age test alone already excludes a
// never-seen path, so deleting the guard leaves the suite green and that is
// EXPECTED. It is kept because the cost is one comparison and the failure it
// blocks -- a clock reading near the zero time counting every unseen pathID as
// live, i.e. never single -- is silent.
func (p *peers) liveLinks(now time.Time) int {
	p.mu.Lock()
	defer p.mu.Unlock()
	n := 0
	for i := range p.seen {
		if !p.seen[i].IsZero() && now.Sub(p.seen[i]) <= EpMaxAge {
			n++
		}
	}
	return n
}

// singleLiveAt reports whether EXACTLY ONE pathID is live (U139). It is wired
// into the resequencer as Ring.SingleLive in main: with one path a seq gap is a
// loss and holding for it is pure stall, so the ring delivers on arrival; the
// moment a second path is live again the hold resumes by itself. Zero live
// paths is NOT single -- an idle server keeps the conservative rule.
func (p *peers) singleLiveAt(now time.Time) bool { return p.liveLinks(now) == 1 }

// attachSingleLive is the ONE line of U139 wiring, lifted out of main() so a
// bar can drive the rule through the real peers table instead of a test stub.
// Deleting the assignment leaves Ring.SingleLive nil and the ring holds every
// gap forever -- the pre-U139 behaviour, which `go test` would otherwise call
// green because every ring test wires its own predicate.
// Pinned by TestAttachSingleLiveDrivesTheRingFromTheRealPeersTable.
func attachSingleLive(r *Ring, p *peers) { r.SingleLive = p.singleLiveAt }

// endpoint returns the address last learned for one link, or nil if this server
// has never accepted a frame on it.
func (p *peers) endpoint(link byte) *net.UDPAddr {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.ep[link]
}

// route returns the link a downlink frame should ride: the one the CLIENT named
// in the last accepted DATA frame's hint, or -- when it named none, or named a
// link this server cannot currently reach -- the link that frame itself rode.
//
// This is deliberately not a scheduler, and U34a does not make it one. The
// policy is entirely the client's: it arrives one byte at a time in the DATA
// frames the client was going to send anyway, and this end holds no weights, no
// quantum, no timer of its own and no constant except the staleness bound above.
// A client that emits no hint (d = 0, which is what every sender emits until a
// policy unit sets otherwise) gets exactly the pre-U34a behaviour -- follow the
// link the client last drew on -- because (pathID + 0) IS pathID.
//
// WHY THE POLICY MUST LIVE ON THE CLIENT AND NOT HERE (spec section 4, C4): this
// box has no physical access. A split baked into this binary can only ever be
// changed by replacing a binary on a box nobody can reach; a split the client
// names can be changed on the recoverable box. That asymmetry is why the hint is
// worth a wire byte at all.
//
// THE FALLBACK IS A0, NEVER A FIXED INDEX. A hint that resolves to a link this
// server has never accepted a frame on (ep == nil), or one whose endpoint is
// older than EpMaxAge, is ignored and the frame rides p.last. There is no branch
// that can route to link 0 by default: index 0 is not privileged anywhere here.
func (p *peers) route() (byte, *net.UDPAddr) { return p.routeAt(time.Now()) }

// routeAt is route with the clock injected, so a test can age an endpoint past
// EpMaxAge without sleeping.
func (p *peers) routeAt(now time.Time) (byte, *net.UDPAddr) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.have {
		return 0, nil
	}
	if t := HintTarget(p.last, p.hint); t != p.last {
		if a := p.ep[t]; a != nil && now.Sub(p.seen[t]) <= EpMaxAge {
			return t, a
		}
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
	// U139: the resequencer asks the peers table how many paths are live and
	// stops holding when the answer is one. Set here, once, before any
	// goroutine exists -- the same discipline as Out/OnOld below.
	attachSingleLive(ring, pr)
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
			// PackRsvd, not Pack: this is a FlagData frame, so byte [3] IS
			// the downlink hint, and the 0 is a statement -- this server asks
			// its peer for no particular uplink link -- not an omission. Same
			// bytes either way (Pack is this call with rsvd = 0); the point is
			// that the one owned call site under the flag the hint belongs to
			// names the field instead of inheriting it (spec item 4).
			m := PackRsvd(out, FlagData, link, 0, dseq, nowMS(), 0, buf[:n])
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

	// resequencer service + stats. What gets EMITTED is decided by the pure
	// statDecision (stat_test.go covers it with no socket): the first line
	// ever, any line whose counters or gate state differ from the last one
	// emitted, or -- an otherwise-silent server -- one heartbeat line every
	// StatHeartbeat. TestStatIdleSilent and TestStatHeartbeat are the two
	// halves of that; a gate transition is just one more field that differs,
	// so it needs no separate case (see statSnapshot's gateShut field).
	go func() {
		t := time.NewTicker(TickIval)
		defer t.Stop()
		last := time.Now()
		var prev statSnapshot
		first := true
		lastEmit := time.Now()
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
			cur := statSnapshot{
				delivs: delivs, towg: atomic.LoadUint64(&statToWG), skip: skips, old: olds, resync: resyncs,
				holdMS:    ring.HoldDur().Milliseconds(),
				dn:        atomic.LoadUint64(&statDnFrames),
				dnnoroute: atomic.LoadUint64(&statDnNoRoute),
				echo:      atomic.LoadUint64(&statEchoTx),
				echoshed:  atomic.LoadUint64(&statEchoShed),
				echonoep:  atomic.LoadUint64(&statEchoNoEp),
				echotrunc: atomic.LoadUint64(&statEchoTrunc),
				bad:       atomic.LoadUint64(&statBad),
				ign:       atomic.LoadUint64(&statIgnored),
				wgerr:     atomic.LoadUint64(&statWGErr),
				authok:    aok, authbad: abad, authshed: ashed,
				sealshort: gate.SealShort(),
				gateShut:  shut,
			}
			if !statDecision(cur, prev, first, now.Sub(lastEmit)) {
				continue
			}
			first = false
			prev = cur
			lastEmit = now
			log.Printf("SSTAT del=%d towg=%d skip=%d old=%d resync=%d hold=%dms dn=%d dnnoroute=%d echo=%d echoshed=%d echonoep=%d echotrunc=%d bad=%d ign=%d wgerr=%d authok=%d authbad=%d authshed=%d sealshort=%d gate=%d",
				cur.delivs, cur.towg, cur.skip, cur.old, cur.resync,
				cur.holdMS,
				cur.dn, cur.dnnoroute,
				cur.echo, cur.echoshed, cur.echonoep, cur.echotrunc,
				cur.bad, cur.ign, cur.wgerr,
				cur.authok, cur.authbad, cur.authshed,
				cur.sealshort, cur.gateShut)
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
