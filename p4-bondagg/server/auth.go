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
	"strings"
	"sync"
	"time"
)

// FRAMING AUTHENTICATION -- a per-install shared secret over the 16-byte header.
//
// WHAT IS AND IS NOT PROTECTED. The payload of a DATA frame is a WireGuard
// datagram: WireGuard already authenticates and replay-protects its own
// contents end to end, and this daemon never looks inside it. What was
// unprotected is the FRAMING the server ACTS on -- the flags byte, the pathID
// that selects a link, the seq the resequencer anchors on, the txstamp that
// sets the reorder horizon, and the LENGTH that turns the meter dial. Those are
// exactly the bytes covered here.
//
// THREAT MODEL (stated so the residuals below are readable, not implied):
//
//	A1 OFF-PATH SPOOFER. Knows the port and the header layout (this repo is the
//	   layout), can forge any source address, cannot observe the client's
//	   frames. This is the attacker the four ROADMAP vectors were written for
//	   and the one this unit is aimed at.
//	A2 ON-PATH OBSERVER. Sees the client's frames and can copy them. Can replay
//	   a captured frame verbatim from its own address. Cannot mint a frame with
//	   a header it has not seen.
//	A3 ON-PATH ACTIVE. Drops, delays and reorders at will. NOT defended: an
//	   attacker who can silence the link owns the link, and no transport MAC
//	   changes that.
//	NOT IN SCOPE: payload confidentiality (WireGuard's), an attacker holding the
//	   install's secret (that is a compromised install, not a forgery), and
//	   traffic analysis.
//
// WHICH POSTURE CLOSES WHAT, AND IT MATTERS MORE THAN THE PRIMITIVE DOES.
// Everything below defends only while the gate is CLOSED, and the gate closes
// only after a frame carrying a valid tag has arrived. So:
//
//   - GATE CLOSED. All four ROADMAP U31 vectors are shut against A1: a forged
//     frame is refused by Admit before it can reach the endpoint table, the
//     meter, the echo budget or the resequencer (rx.go). The residual is A2's
//     replay of a captured frame -- see the open questions in the U31 section
//     of ROADMAP.md.
//   - GATE OPEN. NOTHING here is closed. Every well-formed frame is served, so
//     one forged DATA frame still moves a link's endpoint, still anchors the
//     ring, and -- because the echo follows the LEARNED endpoint -- still lets
//     the attacker aim the echo, one forgery buying both the downlink redirect
//     and the reflection at once. The only structural gain that survives with
//     the gate open is that the ping's own source address is no longer an
//     aiming primitive: reflection now costs a forged DATA frame instead of a
//     free 16-byte ping, and it is loud, because the same forgery redirects the
//     client's downlink. Pinned by TestDegradedGateRefusesToReflectAtThePingSource
//     and TestOpenGateReflectsViaAForgedDataFrame.
//
// THE POSTURE EVERY INSTALL IS IN TODAY IS "GATE OPEN". No key file exists on
// either box (E0/U25 owns /etc/p5, E8/U28 owns getting the secret there, and
// U40 has not read the boxes), and the CLIENT half is a library this repo wires
// into nothing -- the pull client that would call it is U7's and is not on this
// branch. Until both halves are wired and a key is deployed, this unit changes
// the exposure of a running install only by removing the ping-source aiming
// primitive. Read every "closed" below as "closed once a key is on both ends".
//
// THE PRIMITIVE. tag = first MacLen bytes of HMAC-SHA-256(key, dom ||
// hdr[0:16] || be16(payloadLen)), appended AFTER the payload, with FlagAuth set
// in the header's flag nibble so the far side knows the trailer is there. `dom`
// is the one-byte direction tag, domC2S or domS2C -- see DOMAIN SEPARATION at
// the constants below. Proven by TestMacVector (bytes pinned for BOTH
// directions, mirrored in the daemon module), by
// TestMacCoversEveryHeaderByteAndTheLength (every single-bit header mutation and
// every length mutation is rejected) and by TestDomainSeparationBindsDirection.
//
// WHY THE HEADER AND THE LENGTH AND NOT THE PAYLOAD. Cost. The MAC input is
// macInLen = 19 bytes whatever the frame carries, so the whole verification is
// exactly TWO SHA-256 compressions (Go's crypto/hmac keeps the ipad/opad states
// marshalled, so the key blocks are not recompressed): one for the message block
// -- 19 bytes plus SHA-256's 1+8 bytes of padding is 28, still ONE 64-byte
// block, so the domain byte costs nothing -- and one for the 32-byte inner
// digest block. A full-frame MAC over a 1500-byte frame is 25 compressions --
// 12.5x the work, per frame, on a 2-core ARM box that also has to move the
// bytes. MEASURED on the CI runner by the `bench` step of the go-server job
// (BenchmarkAdmitAuthenticated / BenchmarkSeal): read the numbers off the run
// log, not off this comment. See the cost note at the bottom of this file for
// what does and does not transfer to the ARM box.
//
//	RESIDUAL, stated plainly: A2 can capture a frame, swap the payload for
//	anything of the SAME LENGTH, and the tag still verifies. The substituted
//	bytes reach WireGuard, which rejects them under its own AEAD, and the
//	seq is consumed so the genuine frame for that seq is dropped as a
//	duplicate by the ring. Net effect = one lost packet, which A2 could also
//	have achieved by dropping the frame. UNTESTED here: no WireGuard runs in
//	this test suite, so "WireGuard rejects them" is the WireGuard protocol's
//	property, cited, not measured by this unit.
//
// KEY LENGTH is 32 bytes because that is HMAC-SHA-256's output length: RFC 2104
// section 3 recommends a key at least L bytes, and a key longer than the 64-byte
// block would be hashed down to 32 anyway. It is not a tuned number.
//
// MAC TRUNCATION is 8 bytes = 64 bits. Derivation: a blind forgery succeeds with
// probability 2^-64 per attempt, so an attacker filling a gigabit link with
// minimum-size forgeries (about 1.5e6 frames/s, three orders of magnitude above
// what this box can even process) needs 2^64 / 1.5e6 s ~ 4e5 years for one
// expected success. A 4-byte tag under the same arithmetic is about 48 minutes,
// which is not a security bound. 8 bytes is the smallest whole-byte tag that
// puts online forgery beyond any operational horizon. Pinned by
// TestMacTruncationIsEightBytes.
//
//	COST OF THE TRAILER: every authenticated frame is MacLen bytes longer on
//	the wire. At a 1300-byte payload that is 0.6% of goodput, and it raises
//	the outer datagram by 8 bytes. OPEN QUESTION, not answered here: whether
//	the deployed WireGuard MTU has 8 bytes of headroom or must be lowered by
//	8. Nothing in this repo records the deployed MTU, and the boxes have not
//	been read (ROADMAP U40).
const (
	// FlagAuth is a MODIFIER BIT inside the header's 4-bit flag nibble, not a
	// new flag value: an authenticated DATA frame is FlagAuth|FlagData, an
	// authenticated ping is FlagAuth|FlagPing.
	//
	// It is a flag bit and NOT a Ver bump for exactly the reason U16 gave when
	// it added FlagEcho: a version bump hard-fails EVERY frame against a peer
	// that has not been upgraded, and here that peer is a server with no
	// physical access. The base flags in use are 0x0..0x4 (frame.go), so bit
	// 0x8 is free, and a peer that does not know the bit sees flag values
	// 0x8..0xC, which its RX switch does not recognise: the shipped client
	// (daemon/main.go:147) has no default arm and drops them, and this server
	// counts them as ignored. Dropping is the correct degradation. Reusing a
	// KNOWN flag value would be the FlagEcho/FlagPong misparse again.
	// Pinned by TestFlagAuthDoesNotCollide.
	FlagAuth = 0x8
	// MacLen is the truncated tag length in bytes. See the derivation above.
	MacLen = 8
	// KeyLen is the shared secret length in bytes. See the derivation above.
	KeyLen = 32
	// MaxAuthFrame bounds the RX buffer: the largest frame the wire can carry
	// (frame.go MaxFrame) plus the trailer. frame.go is left byte-identical to
	// the client's mirror; the trailer is added here.
	MaxAuthFrame = MaxFrame + MacLen

	// DOMAIN SEPARATION. domC2S and domS2C are the one-byte direction tag
	// PREPENDED to the MAC input. Nothing in the 16-byte header encodes which
	// way a frame is travelling -- flags, pathID, seq, txstamp and fseq all have
	// the same meaning in both directions -- so without this byte a
	// client->server frame and a server->client frame with the same header
	// authenticate under exactly the same tag, and a tag minted by one end is a
	// valid tag at the other. Concretely: the server's own signed echo, replayed
	// back at the server, verifies as an uplink frame from the client. With the
	// tag bound to the direction it does not. Pinned by
	// TestDomainSeparationBindsDirection and by TestMacVector, which pins the
	// two directions to two different byte strings over the SAME header.
	//
	// WHY THIS FORM. A prefix, because the domain must be fixed and unambiguous
	// ahead of the bytes it separates. ONE BYTE, because there are exactly two
	// directions and because 19 bytes of input still fits a single SHA-256
	// block, so the whole "exactly two compressions per verify" cost argument is
	// unchanged -- a longer label would have been free too, and would have said
	// no more. NONZERO values, so that a zeroed byte -- a mirror copy that
	// forgot the prefix, a scratch buffer never written -- is not a valid domain
	// in either direction and fails closed rather than silently reproducing the
	// undomained tag.
	//
	// WHAT IT DOES NOT BIND, recorded as open question 5 in the U31 section of
	// ROADMAP.md rather than left implied: it separates the two DIRECTIONS and
	// nothing else. It does not bind the install, so two installs that share a
	// key still authenticate each other; it does not bind the session, so it is
	// not anti-replay (open question 1); and the direction is LOCAL
	// configuration (macRole), not a wire field, so a gate built with the wrong
	// role does not fail loudly -- it verifies nothing, the gate never closes,
	// and the tunnel runs unauthenticated. That failure is deliberately in the
	// reopen rule's fail-open direction, because the alternative on a box with
	// no console is a lockout.
	domC2S = 0x01
	domS2C = 0x02

	// macInLen is the MAC input length: the domain byte, the whole header, and a
	// big-endian uint16 payload length.
	macInLen = 1 + HdrLen + 2
	// keyFileMax bounds the key-file read. A key line is 64 hex characters plus
	// a newline, so this is roughly a thousand lines: it is an I/O sanity guard
	// against AGG_KEY_FILE pointing at a device or a large file, NOT a policy
	// on how many keys are reasonable. Two is the number a rollover needs.
	keyFileMax = 64 << 10
)

// KeyFileDefault is where the per-install secret is read from when AGG_KEY_FILE
// is unset. It sits under /etc/p5 with the rest of the P5 install state.
//
// OPEN, and it must be agreed rather than assumed: E0's install skeleton
// (ROADMAP U25) owns what actually exists under /etc/p5, the package (E8, U28)
// owns getting the same 32 bytes onto BOTH boxes, and neither has been read on
// hardware (U40). This constant is this daemon's half of a contract whose other
// half is not written yet.
const KeyFileDefault = "/etc/p5/transport.key"

// ReopenDefault is the silence horizon after which the gate REOPENS -- see the
// authGate comment for what that means and why the failure it prevents is worse
// than the exposure it costs.
//
// NOT DERIVED, and reported as such. Physics gives a floor only: the horizon
// must exceed the longest gap between authenticated frames that a HEALTHY
// tunnel can produce, and the longest liveness timer either end runs is the
// client's DeadIval = 600 ms (daemon/main.go:29). 30 s is 50x that floor, so no
// datapath transient can reach it, and it is short enough that an operator
// watching a botched key rollover sees the tunnel come back rather than
// concluding the box is lost. Everything above the 600 ms floor is a judgement
// about human recovery time, not a measurement. Operator knob
// AGG_AUTH_REOPEN_MS, in the same posture as txBackoff: a number with no
// physical derivation behind it, logged as such.
const ReopenDefault = 30 * time.Second

// ReopenFloor is the SMALLEST horizon this daemon will run with, and it is now
// enforced in code rather than only asserted in prose.
//
// DERIVED, not chosen. The gate is CLOSED for `reopen` after each verified
// frame (closedLocked), so a horizon SHORTER than the gap between authenticated
// frames leaves the gate OPEN between them and every forgery in that gap is
// admitted -- with authok climbing normally and nothing in the log saying the
// gate is not actually shut. The floor must therefore exceed the longest gap a
// HEALTHY tunnel can produce, and the longest such gap is the peer's liveness
// timer: DeadIval = 600 ms (daemon/main.go:29). A peer still considered ALIVE
// has by definition sent something within 600 ms. Below that the horizon is not
// a weaker setting, it is a gate that does not close.
//
// It is not imported from daemon/main.go: that is a different Go module and
// this file is a hand-kept mirror, like frame.go. If DeadIval ever moves, this
// constant moves with it -- pinned by TestReopenFloorMatchesPeerLiveness.
//
// THE OTHER DIRECTION IS STILL UNDEFENDED AND STILL OPEN (ROADMAP U31 open
// question 7): a very LARGE horizon turns a key mismatch into an outage of that
// length on a box with no console. No physics bounds it from above, so nothing
// is invented here -- it is logged, and it stays the operator's.
const ReopenFloor = 600 * time.Millisecond

// clampReopen applies ReopenFloor, loudly. Same shape and the same reason as
// main.go's holdMax<holdMin clamp two lines above its call site: a configuration
// value that cannot do its job is corrected to the nearest value that can, and
// the correction is logged, so the daemon still starts (no console) but nobody
// reads the startup line as normal. Pinned by TestClampReopenAppliesTheFloor.
func clampReopen(d time.Duration) time.Duration {
	if d < ReopenFloor {
		log.Printf("config: AGG_AUTH_REOPEN_MS=%v is below the %v floor -- the gate is "+
			"only CLOSED for that long after each verified frame, so a horizon shorter "+
			"than the peer's liveness timer (DeadIval 600ms) leaves it OPEN between "+
			"frames and admits every forgery in the gap while authok keeps climbing. "+
			"Clamping to %v.", d, ReopenFloor, ReopenFloor)
		return ReopenFloor
	}
	return d
}

// LoadKeys reads the per-install secret file: one 64-hex-character key per line,
// '#' comments and blank lines skipped. Every accepted key VERIFIES; the key
// used to SIGN is chosen per-peer at run time (see authGate.Seal), never by
// position in this file.
//
// A line that is not KeyLen hex-encoded bytes is logged and skipped rather than
// fatal: a truncated or hand-edited key file must not stop a daemon on a box
// with no console. A file with no usable line yields zero keys, which turns
// authentication OFF (see newAuthGate) instead of refusing to run.
//
// Generate one on either box with busybox:
//
//	od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > /etc/p5/transport.key
//	chmod 600 /etc/p5/transport.key
//
// Proven by TestLoadKeysParsesAndSkipsJunk.
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

// authGate is the accept/sign decision for one peer.
//
// THE ONE RULE, and it is the whole design:
//
//	The gate is CLOSED while a VALID tag has been seen within the reopen
//	horizon. While closed, only frames carrying a valid tag are served, and
//	the reply is signed with the key that verified. Otherwise the gate is
//	OPEN and everything is served unsigned -- exactly the behaviour this
//	daemon had before this unit.
//
// WHY IT IS BUILT THIS WAY, and this is the constraint that decided it: the
// server has NO PHYSICAL ACCESS (HANDOFF section 0a). A rule that can reject the
// legitimate client on a configuration mismatch loses the box permanently. Under
// this rule a mismatch cannot: if the client's tags stop verifying, the last
// valid tag ages out, the gate reopens, and the tunnel comes back UNAUTHENTICATED
// within the horizon. The operator sees authfail climbing in SSTAT and fixes the
// key with the tunnel up. Proven by TestGateReopensAfterAKeyMismatch and
// TestMismatchedKeyKeepsThePayloadIntact.
//
// The symmetric worry -- can an attacker force the gate open? -- has one answer:
// the gate closes on any valid tag and an attacker cannot produce one, so the
// only way to hold it open is to stop the legitimate client's frames from
// arriving for the whole horizon, which is attacker A3, who already owns the
// link. Proven by TestForgedFramesDoNotRefreshTheGate.
//
// A gate with NO KEYS never closes, so a server whose key file is missing serves
// its client exactly as it did before this unit rather than refusing it.
// Proven by TestGateWithoutKeysNeverCloses.
//
// LOCKING. One mutex covers the gate state and the hmac objects, which are NOT
// safe for concurrent use. Admit runs on the RX goroutine and Seal on the
// downlink goroutine, so a lock is genuinely needed; the critical section is two
// SHA-256 compressions. The `race` step of the go-server job is what proves that
// claim, and it has now RUN: green on bond-ci run 33323754729, which is the
// first run in which any of this file compiled.
type authGate struct {
	mu        sync.Mutex
	macs      []hash.Hash
	scratch   []byte
	lastOK    time.Time
	lastKey   int
	haveOK    bool
	reopen    time.Duration
	sealDom   byte
	verifyDom byte
	authOK    uint64
	authBad   uint64
	authShd   uint64
	sealShort uint64
}

// macRole is which END of the tunnel this gate runs on. It selects the two
// domain bytes and nothing else. It is LOCAL configuration: no wire field
// carries it, both ends simply know which binary they are. This daemon always
// builds roleServer (main.go); roleClient exists here so a test can stand up the
// far end of the wire in this module, and so the two mirrored copies of this
// file stay byte-comparable.
type macRole int

const (
	roleClient macRole = iota
	roleServer
)

// newAuthGate builds a gate over keys (possibly empty: that is authentication
// OFF) with the given reopen horizon, signing and verifying in the directions
// role implies.
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

// SealShort reports how many frames Seal refused for lack of trailer headroom.
// A CALLER-BUG counter: it should be zero forever, and it is in the SSTAT line
// so that if it ever is not, the log names the cause instead of leaving a stall
// to be explained.
func (g *authGate) SealShort() uint64 {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.sealShort
}

// Counts reports (verified, failed, shed) for the stats line.
func (g *authGate) Counts() (uint64, uint64, uint64) {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.authOK, g.authBad, g.authShd
}

// macLocked writes the tag for hdr (which must be the full HdrLen header, with
// FlagAuth already set) and a payload of payLen bytes into dst[:MacLen], in
// direction dom, using key index i. Callers MUST hold g.mu.
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
	// admitPass: the frame may touch server state.
	admitPass admit = iota
	// admitMalformed: not a frame this daemon can parse at all.
	admitMalformed
	// admitShed: a well-formed frame refused because the gate is closed and it
	// carried no valid tag. This is where a forgery dies.
	admitShed
)

// inFrame is one accepted frame, already stripped of its tag.
type inFrame struct {
	pay    []byte
	seq    uint32
	ts     uint32
	base   byte
	pid    byte
	authed bool
}

// Admit parses one received datagram and decides whether it may touch any
// server state. It is the ONLY entry point to the header: nothing else in this
// daemon calls Unpack on a received buffer.
//
// A frame carrying FlagAuth has its MacLen-byte trailer stripped WHETHER OR NOT
// the tag verifies. That is deliberate: on a key mismatch the gate reopens and
// the frame is served, and it can only be served correctly if the payload
// boundary is the one the sender used. Leaving the trailer on the payload would
// hand WireGuard 8 junk bytes on every packet and the "mismatch degrades to
// unauthenticated" property would be a lie. Proven by
// TestMismatchedKeyKeepsThePayloadIntact.
//
// f.pay aliases b. The caller must not retain it past the frame.
func (g *authGate) Admit(b []byte, now time.Time) (inFrame, admit) {
	fl, pid, seq, ts, _, pay, err := Unpack(b)
	if err != nil {
		return inFrame{}, admitMalformed
	}
	f := inFrame{base: fl &^ FlagAuth, pid: pid, seq: seq, ts: ts, pay: pay}
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

// verify checks the trailer of b against every loaded key. It returns true and
// closes the gate on the first key that matches, and remembers WHICH key that
// was so the reply can be signed with it (see Seal).
//
// Cost is one MAC per key TRIED, so a forged frame costs len(keys) MACs. The
// rollover procedure never needs more than two keys loaded at once; a file with
// more is accepted (LoadKeys does not cap it) and simply costs that many MACs
// per unverifiable frame. Stated, not defended against.
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
// length. It sets FlagAuth and appends the tag; buf must have MacLen spare bytes.
//
// It signs ONLY while the gate is closed, and it signs with the key that last
// verified an incoming frame -- never with a key chosen by position. Two
// consequences, both of them the point:
//
//   - A peer that has never proved it speaks this protocol is answered
//     UNSIGNED, so upgrading this server before the client cannot black-hole
//     the client: an un-upgraded client would drop a FlagAuth frame as an
//     unknown flag value and lose its downlink entirely. Proven by
//     TestSealIsSilentUntilThePeerHasProvenItself.
//   - Mid-rollover, a client that holds only the NEW key is answered with the
//     new key, because that is the key its own frames verified under. The
//     server's key ORDER never matters, only membership. Proven by
//     TestSealUsesTheKeyThatVerified.
//
// buf MUST have MacLen spare bytes past n. This server's own TX buffers are
// sized for it (main.go downlink `HdrLen+MaxPayload+MacLen`, rx.go echoOut
// `MaxAuthFrame`), so the guard below should never fire here; it is mirrored
// from daemon/auth.go, where a caller following the integration recipe against
// buffers sized MaxPayload+HdrLen wrote past the end. Returning -1 rather than
// panicking is deliberate: a panic here is a daemon gone on a box with no
// console (HANDOFF 0a), and returning n unsealed would emit FlagAuth with no
// tag, which the peer sheds as a forgery -- a silent stall that looks exactly
// like a bad key. Caller drops the frame and counts it.
func (g *authGate) Seal(buf []byte, n int, now time.Time) int {
	g.mu.Lock()
	defer g.mu.Unlock()
	if len(g.macs) == 0 || !g.closedLocked(now) {
		return n
	}
	if n < HdrLen || n+MacLen > len(buf) {
		g.sealShort++
		return -1
	}
	buf[1] |= FlagAuth
	g.macLocked(g.lastKey, g.sealDom, buf, n-HdrLen, buf[n:n+MacLen])
	return n + MacLen
}

// PER-FRAME COST, measured and bounded.
//
// MEASURED on the CI runner by BenchmarkAdmitAuthenticated / BenchmarkSeal,
// which the `bench` step of the go-server job RUNS on every push (x86-64, one
// key loaded). Read the numbers off that step's log, not off this comment: a
// number written here would rot, and this file must not cite a measurement it
// does not contain. The step exists because the first version of this comment
// claimed a measurement while the note here said the benchmarks had never been
// run anywhere -- the claim and the disclaimer were in the same file.
//
// BOUNDED analytically, which is the part that transfers to the box CI cannot
// run on: the MAC input is macInLen = 1 + HdrLen + 2 = 19 bytes regardless of
// frame size, so a verify or a seal is EXACTLY two SHA-256 compressions of a
// 64-byte block, plus a fixed 19-byte copy and an 8-byte compare. Per DATA frame the server does one
// verify; per downlink frame, one seal. So the added work at F frames/s in each
// direction is 4F compressions/s, independent of frame size and of N.
//
// UNMEASURED, and named so: the ARM cost. CI is x86-64 only and neither box has
// been read (ROADMAP U40, "everything is a hypothesis until this exists"), so
// the cycles-per-SHA-256-block figure for a GL-MT2500 -- which depends on
// whether its cores carry the ARMv8 SHA-2 extension, and therefore on a ratio of
// roughly 8x between the two answers -- is NOT known here. What IS known is the
// shape: constant per frame, four compressions per frame round trip, and 12.5x
// less than the same construction over a full 1500-byte frame.
