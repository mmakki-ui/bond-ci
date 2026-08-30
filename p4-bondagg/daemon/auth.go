package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"hash"
	"io"
	"log"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// FRAMING AUTHENTICATION, client half -- a VERBATIM MIRROR of
// p4-bondagg/server/auth.go, duplicated for the same reason frame.go is: the
// server is a separate Go module, so shared wire code is copied rather than
// imported, and any change to one copy MUST be made to the other or the two
// peers stop authenticating each other. The FULL design argument -- threat
// model, why the MAC covers the header and the length and not the payload, the
// key length and truncation derivations, the reopen rule and the degradation it
// buys -- is written once, in server/auth.go. Do not re-derive it here; read it
// there.
//
// The one construction, restated so this file is checkable on its own:
//
//	tag = first MacLen bytes of HMAC-SHA-256(key, dom || hdr[0:16] ||
//	be16(payloadLen)), appended after the payload, with FlagAuth set in the
//	header's flag nibble. dom is the one-byte direction tag: this end SEALS
//	with domC2S and VERIFIES with domS2C, the server does the reverse.
//
// Pinned to the same out-of-Go vectors as the server copy: TestMacVector here
// and TestMacVector in server/auth_test.go assert the SAME bytes, for BOTH
// directions, for the same input. That pair of tests is the only thing keeping
// the two copies honest.
//
// WHO CALLS THIS. The PULL client (AGG_MODE=pull-client: pull.go + pullrun.go)
// wires it in at four points, and those four are the whole integration:
//
//  1. on send, after Pack:      n = gate.Seal(buf, n, now), gated on
//     gate.SendAuth(now, lastRxFromPeer)   -- pull.go PullLink.send
//  2. on receive, before use:   f, v := gate.Admit(buf[:n], now)  -- pullrun.go
//  3. in the sent-bytes meter:  count the SEALED length, because that is what
//     the server counts on arrival (server/rx.go). The pull client counts the
//     WriteToUDP return, which is already the sealed length.
//  4. every TX and RX buffer is sized for the trailer -- see BUFFER SIZES below.
//
// The shipped PUSH client (runClient/runServer in main.go, plus eif.go /
// estr.go / qtrack2.go / fec.go / ring.go / paths.go / util*.go) is DEPLOYED
// and is left byte-identical by this unit: it is frozen reference code, its
// peer is the pre-U31 push server, and sealing its frames would buy nothing
// while risking the one stack that works.
//
// BUFFER SIZES, and this paragraph is the reason it is a numbered point of its
// own. Seal appends MacLen bytes AFTER the packed frame, so every buffer a
// sealed frame is built in needs MacLen bytes of headroom past what Pack
// returns, and every buffer a sealed frame is READ into needs MacLen bytes past
// the largest unsealed frame. The recipe used to omit this, and following it
// against the pull client's own buffers was a panic and a truncation:
//
//	TX data:  MaxPayload + HdrLen + MacLen   (pull.go PullSendBufLen)
//	TX ping:  HdrLen + MacLen
//	TX pong:  HdrLen + pongLen + MacLen
//	RX:       MaxAuthFrame  ( = MaxFrame + MacLen )
//
// An RX buffer of MaxFrame silently truncates a full-size sealed frame by
// exactly the trailer, and a truncated tag is indistinguishable from a bad one:
// the link would fail closed with authbad climbing on nothing. Seal itself now
// REFUSES a short buffer (returns -1) rather than writing past it, so a caller
// that gets this wrong loses frames loudly instead of panicking a router that
// nobody can physically reach -- but the sizes above are what makes it a
// non-event. Pinned by TestSealRefusesAShortBuffer and
// TestPullSendBuffersCarryTheTrailer.
const (
	// FlagAuth is a MODIFIER BIT in the header's 4-bit flag nibble, not a new
	// flag value, and not a Ver bump: a version bump hard-fails EVERY frame
	// against a peer that has not been upgraded. The base flags in use are
	// 0x0..0x4 (frame.go FlagData/FlagPing/FlagPong, fec.go FlagFEC, and the
	// server's FlagEcho = 0x4), so bit 0x8 is free, and a peer that does not
	// know the bit sees an unknown flag value and drops the frame -- the RX
	// switch in main.go:147 has no default arm. Pinned by
	// TestFlagAuthDoesNotCollide.
	FlagAuth = 0x8
	// MacLen is the truncated tag length in bytes. Derivation in server/auth.go.
	MacLen = 8
	// KeyLen is the shared secret length in bytes. Derivation in server/auth.go.
	KeyLen = 32
	// MaxAuthFrame bounds an RX buffer: the largest frame the wire can carry
	// plus the trailer. frame.go stays byte-identical; the trailer is added here.
	MaxAuthFrame = MaxFrame + MacLen

	// DOMAIN SEPARATION: the one-byte direction tag prepended to the MAC input.
	// Nothing in the header says which way a frame travels, so without this a tag
	// minted by one end is a valid tag at the other -- the server's own signed
	// echo, replayed at the server, would verify as an uplink frame. Full
	// derivation (why a prefix, why one byte, why nonzero, and what it does NOT
	// bind) is in server/auth.go. Pinned by TestDomainSeparationBindsDirection.
	domC2S = 0x01
	domS2C = 0x02

	// macInLen is the MAC input length: the domain byte, the whole header, and a
	// big-endian uint16 payload length.
	macInLen = 1 + HdrLen + 2
	// keyFileMax bounds the key-file read: an I/O sanity guard against
	// AGG_KEY_FILE pointing at a device, not a policy on key count.
	keyFileMax = 64 << 10
)

// KeyFileDefault is where the per-install secret is read from. It is the SAME
// path and the SAME 32 bytes on both boxes -- one secret per install, not per
// box, and not per link.
const KeyFileDefault = "/etc/p5/transport.key"

// ReopenDefault is the silence horizon after which the gate reopens. NOT
// DERIVED above its floor -- see server/auth.go for the full statement. The
// floor is the longest liveness timer either end runs, DeadIval = 600 ms
// (main.go:29); everything above it is a judgement about human recovery time.
const ReopenDefault = 30 * time.Second

// ReopenFloor is the smallest horizon this client will run with. MIRROR of
// server/auth.go ReopenFloor -- read the derivation there. Short form: the gate
// is CLOSED only for `reopen` after each verified frame, so a horizon shorter
// than the longest gap a healthy tunnel produces leaves it OPEN between frames
// and admits every forgery in the gap while authok climbs normally. The longest
// such gap is DeadIval = 600 ms (main.go:29), which this module DOES have, so
// the floor is expressed in terms of it rather than restated as a number.
// Pinned by TestReopenFloorMatchesPeerLiveness.
const ReopenFloor = DeadIval

// clampReopen applies ReopenFloor, loudly. MIRROR of server/auth.go.
// Pinned by TestClampReopenAppliesTheFloor.
func clampReopen(d time.Duration) time.Duration {
	if d < ReopenFloor {
		log.Printf("config: AGG_AUTH_REOPEN_MS=%v is below the %v floor -- the gate is "+
			"only CLOSED for that long after each verified frame, so a horizon shorter "+
			"than the peer's liveness timer (DeadIval) leaves it OPEN between frames "+
			"and admits every forgery in the gap while authok keeps climbing. "+
			"Clamping to %v.", d, ReopenFloor, ReopenFloor)
		return ReopenFloor
	}
	return d
}

// envMS reads a millisecond integer from the environment. Same shape as the
// server's (server/main.go): a value that is not a positive integer is logged
// and IGNORED rather than fatal -- a bad config line must not stop the daemon.
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

// LoadKeys reads the per-install secret file: one 64-hex-character key per line,
// '#' comments and blank lines skipped. Unusable lines are logged and skipped,
// never fatal. Proven by TestLoadKeysParsesAndSkipsJunk.
func LoadKeys(path string) ([][]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, keyFileMax))
	if err != nil {
		return nil, err
	}
	var keys [][]byte
	for _, ln := range strings.Split(string(raw), "\n") {
		if i := strings.IndexByte(ln, '#'); i >= 0 {
			ln = ln[:i]
		}
		ln = strings.TrimSpace(ln)
		if ln == "" {
			continue
		}
		k, derr := hex.DecodeString(ln)
		if derr != nil || len(k) != KeyLen {
			log.Printf("auth: %s: skipping a line that is not %d hex-encoded bytes", path, KeyLen)
			continue
		}
		keys = append(keys, k)
	}
	return keys, nil
}

// authGate is the accept/sign decision for one peer. Mirror of the server type,
// plus the client-only send-side fallback (SendAuth).
//
// THE ONE RULE: the gate is CLOSED while a valid tag has been seen within the
// reopen horizon; while closed only tagged frames are served and replies are
// signed with the key that verified. Otherwise it is OPEN and everything is
// served unsigned. A gate with no keys never closes.
type authGate struct {
	mu        sync.Mutex
	macs      []hash.Hash
	scratch   []byte
	lastOK    time.Time
	firstTx   time.Time
	lastKey   int
	haveOK    bool
	haveTx    bool
	fellBack  bool
	reopen    time.Duration
	sealDom   byte
	verifyDom byte
	authOK    uint64
	authBad   uint64
	authShd   uint64
	sealShort uint64
}

// macRole is which END of the tunnel this gate runs on: it selects the two
// domain bytes and nothing else. LOCAL configuration, carried by no wire field.
// The pull client that wires this library in builds roleClient; roleServer
// exists here so a test can stand up the far end of the wire inside this module,
// and so the two mirrored copies of this file stay byte-comparable.
type macRole int

const (
	roleClient macRole = iota
	roleServer
)

func newAuthGate(keys [][]byte, reopen time.Duration, role macRole) *authGate {
	g := &authGate{reopen: reopen, scratch: make([]byte, 0, sha256.Size)}
	g.sealDom, g.verifyDom = domS2C, domC2S
	if role == roleClient {
		g.sealDom, g.verifyDom = domC2S, domS2C
	}
	for _, k := range keys {
		g.macs = append(g.macs, hmac.New(sha256.New, k))
	}
	return g
}

// Enabled reports whether any key was loaded.
func (g *authGate) Enabled() bool { return len(g.macs) > 0 }

// Closed reports whether the gate is currently refusing unauthenticated frames.
func (g *authGate) Closed(now time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.closedLocked(now)
}

func (g *authGate) closedLocked(now time.Time) bool {
	return g.haveOK && now.Sub(g.lastOK) < g.reopen
}

// Counts reports (verified, failed, shed) for a stats line.
func (g *authGate) Counts() (uint64, uint64, uint64) {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.authOK, g.authBad, g.authShd
}

// SealShort reports how many frames Seal refused for lack of trailer headroom.
// It is a CALLER-BUG counter and it should be zero forever; it is reported in
// the pull client's STAT line so that if it is ever non-zero the cause is named
// in the log rather than inferred from a stall.
func (g *authGate) SealShort() uint64 {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.sealShort
}

// macLocked writes the tag for hdr (the full HdrLen header, FlagAuth already
// set) and a payload of payLen bytes into dst[:MacLen], in direction dom, under
// key i. Callers MUST hold g.mu.
func (g *authGate) macLocked(i int, dom byte, hdr []byte, payLen int, dst []byte) {
	var in [macInLen]byte
	in[0] = dom
	copy(in[1:1+HdrLen], hdr[:HdrLen])
	binary.BigEndian.PutUint16(in[1+HdrLen:], uint16(payLen))
	m := g.macs[i]
	m.Reset()
	m.Write(in[:])
	g.scratch = m.Sum(g.scratch[:0])
	copy(dst[:MacLen], g.scratch)
}

// admit is the verdict of Admit.
type admit int

const (
	// admitPass: the frame may be used.
	admitPass admit = iota
	// admitMalformed: not a frame this build can parse at all.
	admitMalformed
	// admitShed: well-formed, refused because the gate is closed and it carried
	// no valid tag. This is where a forgery dies.
	admitShed
)

// inFrame is one accepted frame, already stripped of its tag.
type inFrame struct {
	pay    []byte
	seq    uint32
	ts     uint32
	fseq   uint32
	base   byte
	pid    byte
	authed bool
}

// Admit parses one received datagram and decides whether it may be used.
//
// A frame carrying FlagAuth has its trailer stripped WHETHER OR NOT the tag
// verifies, so that a key mismatch degrades to an unauthenticated tunnel rather
// than to a corrupted one. Proven by TestMismatchedKeyKeepsThePayloadIntact.
//
// f.pay aliases b.
func (g *authGate) Admit(b []byte, now time.Time) (inFrame, admit) {
	fl, pid, seq, ts, fseq, pay, err := Unpack(b)
	if err != nil {
		return inFrame{}, admitMalformed
	}
	f := inFrame{base: fl &^ FlagAuth, pid: pid, seq: seq, ts: ts, fseq: fseq, pay: pay}
	if fl&FlagAuth != 0 {
		if len(b) < HdrLen+MacLen {
			return inFrame{}, admitMalformed
		}
		f.pay = b[HdrLen : len(b)-MacLen]
		f.authed = g.verify(b, now)
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if !f.authed && g.closedLocked(now) {
		g.authShd++
		return inFrame{}, admitShed
	}
	return f, admitPass
}

// verify checks the trailer of b against every loaded key, remembering which key
// matched so a reply can be signed with it. Cost is one MAC per key TRIED.
func (g *authGate) verify(b []byte, now time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if len(g.macs) == 0 {
		return false
	}
	var want [MacLen]byte
	payLen := len(b) - HdrLen - MacLen
	got := b[len(b)-MacLen:]
	for i := range g.macs {
		g.macLocked(i, g.verifyDom, b, payLen, want[:])
		if subtle.ConstantTimeCompare(want[:], got) == 1 {
			g.lastOK = now
			g.lastKey = i
			g.haveOK = true
			g.authOK++
			return true
		}
	}
	g.authBad++
	return false
}

// Seal signs a frame built by Pack in buf[:n], in place, and returns the new
// length. buf MUST have MacLen spare bytes past n; see BUFFER SIZES at the top
// of this file for every buffer in the pull client and its required size.
//
// A buffer without that headroom returns -1 and seals nothing. That case is a
// caller bug, not a runtime condition, and the three ways it could have been
// handled are not equivalent:
//   - writing anyway is an index-out-of-range PANIC, which on the server box
//     means a daemon that is gone and a box with no console (HANDOFF 0a);
//   - returning n unsealed emits a frame with FlagAuth SET and no tag, which
//     the peer counts as a forgery and sheds -- a silent stall that looks
//     exactly like a bad key;
//   - refusing is one frame lost, attributable, and countable.
//
// The caller drops the frame and counts it (pull.go send -> sendPathDown).
// Pinned by TestSealRefusesAShortBuffer.
//
// It signs with the key that last verified an incoming frame if there is one,
// and otherwise with the FIRST loaded key. That last part is the difference
// between this copy and the server's: the client INITIATES. The server only ever
// answers, so it can refuse to sign until the peer has proven itself; if the
// client did the same, neither end would ever start. Which key the client
// signs with is therefore its own choice, and the rollover procedure is written
// around that: the new key is added to both ACCEPT sets first, and only then
// moved to the front of the client's file. Pinned by
// TestClientSignsWithTheFirstKeyUntilAPeerVerifies.
func (g *authGate) Seal(buf []byte, n int, now time.Time) int {
	g.mu.Lock()
	defer g.mu.Unlock()
	if len(g.macs) == 0 {
		return n
	}
	if n < HdrLen || n+MacLen > len(buf) {
		g.sealShort++
		return -1
	}
	k := 0
	if g.haveOK {
		k = g.lastKey
	}
	buf[1] |= FlagAuth
	g.macLocked(k, g.sealDom, buf, n-HdrLen, buf[n:n+MacLen])
	return n + MacLen
}

// SendAuth is the CLIENT-ONLY half: whether this frame should be sealed at all.
//
// The failure it exists for: a client that has a key and a server that does not
// UNDERSTAND FlagAuth (a pre-U31 binary) drops every frame the client sends as
// an unknown flag value, and the tunnel is dead with no error anywhere. The
// client is the box that can be physically reached (HANDOFF section 0a), so it
// carries the recovery: after the reopen horizon of sealing into total silence,
// it falls back to sending unauthenticated frames.
//
// The fallback is STICKY until the process restarts. That is the deliberate
// choice: the alternative -- retry after another horizon -- oscillates between a
// working tunnel and a dead one forever, which is worse than a tunnel that is
// simply up and loudly unauthenticated. It also means an attacker who can
// black-hole the client for one horizon can strip its authentication until it is
// restarted; that attacker is A3 in the server's threat model, who can silence
// the link anyway. Named, not defended against.
//
// lastRx is when ANY frame was last received from the peer. Proven by
// TestSendAuthFallsBackOnSilence and TestSendAuthStaysOnOnceThePeerVerifies.
func (g *authGate) SendAuth(now, lastRx time.Time) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if len(g.macs) == 0 {
		return false
	}
	if g.haveOK {
		return true
	}
	if g.fellBack {
		return false
	}
	if !g.haveTx {
		g.haveTx = true
		g.firstTx = now
		return true
	}
	if now.Sub(g.firstTx) >= g.reopen && now.Sub(lastRx) >= g.reopen {
		g.fellBack = true
		log.Printf("auth: no reply for %v while sending authenticated frames -- "+
			"falling back to UNAUTHENTICATED until restart (peer too old, or key file "+
			"only on this end)", g.reopen)
		return false
	}
	return true
}
