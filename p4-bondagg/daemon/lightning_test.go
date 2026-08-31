package main

import (
	"strings"
	"syscall"
	"testing"
	"time"
)

// =============================================================================
// U15b / E2c tests.
//
// Every behavioural claim in lightning.go's header names one of these. Two
// claims deliberately do NOT, and both say so in the header rather than being
// covered by a test that does not measure them:
//   * the PEER half of first-wins (server/ring.go is a different Go module and
//     nothing here compiles it), and
//   * the SIZE of the head-of-line cost a copy write imposes on a host link
//     (needs a real device queue; nothing in P5 has run on hardware).
//
// The seam these use is U7's: fakeSock / testDst / waitFor from
// pullsend_test.go. No new fake is introduced.
// =============================================================================

// litLinks builds n links over fake sockets with the given device names.
func litLinks(names []string, socks []*fakeSock) *PullCore {
	c := &PullCore{FIFO: NewPullFIFO()}
	for i := range names {
		c.Links = append(c.Links, newPullLinkSock(i, names[i], socks[i], testDst()))
	}
	return c
}

func litSocks(n int, outcomes ...error) []*fakeSock {
	s := make([]*fakeSock, n)
	for i := range s {
		s[i] = newFakeSock(0, outcomes...)
	}
	return s
}

// litFor builds a Lightning directly over a core with an explicit class vector,
// bypassing the environment. NewLightning's own fact parsing is covered
// separately by TestLightningClassComesFromTheFactNotTheName.
func litFor(c *PullCore, spotty []bool) *Lightning {
	return &Lightning{
		links:   c.Links,
		spotty:  spotty,
		perLink: make([]uint64, len(c.Links)),
	}
}

func litFrame(seq uint32, n int) *PullFrame {
	return &PullFrame{seq: seq, enq: time.Now(), payload: make([]byte, n)}
}

// seqsOf decodes the seq field of every frame a fake socket was handed.
func seqsOf(t *testing.T, ws []fakeWrite) []uint32 {
	t.Helper()
	out := make([]uint32, 0, len(ws))
	for i, w := range ws {
		_, _, sq, _, _, _, err := Unpack(w.b)
		if err != nil {
			t.Fatalf("write %d is not a decodable frame: %v", i, err)
		}
		out = append(out, sq)
	}
	return out
}

// ---------------------------------------------------------------------------
// FLAG AND DEFAULT
// ---------------------------------------------------------------------------

// The default is OFF and the off state is a nil *Lightning, so the daemon runs
// U7's loop unchanged.
func TestLightningIsOffByDefault(t *testing.T) {
	t.Setenv("AGG_LIGHTNING", "")
	t.Setenv("AGG_SPOTTY", "usb0")
	c := litLinks([]string{"eth0", "usb0"}, litSocks(2))
	if lit := NewLightning(c, []string{"eth0", "usb0"}); lit != nil {
		t.Fatalf("AGG_LIGHTNING unset must be OFF (nil), got %+v", lit)
	}
}

// An unparseable flag value is treated as OFF, not as ON.
func TestLightningUnknownFlagValueIsOff(t *testing.T) {
	t.Setenv("AGG_LIGHTNING", "yes")
	c := litLinks([]string{"eth0", "usb0"}, litSocks(2))
	if lit := NewLightning(c, []string{"eth0", "usb0"}); lit != nil {
		t.Fatal("AGG_LIGHTNING=yes must be treated as OFF")
	}
}

// Every method is safe on the OFF (nil) receiver, which is what lets pullrun.go
// call them without a branch.
func TestLightningNilReceiverIsInert(t *testing.T) {
	var lit *Lightning
	c := litLinks([]string{"eth0"}, litSocks(1))
	lit.Nominate(c.Links[0], litFrame(1, 10), time.Now())
	if fr, ok := lit.Take(c.Links[0], time.Now()); ok || fr != nil {
		t.Fatal("nil Take must report nothing")
	}
	lit.Sent(c.Links[0])
	lit.Refused()
	lit.Tick(time.Now(), time.Second)
	lit.SetRoom(func(*PullLink) bool { return true })
	if s := lit.Stat(); s != "" {
		t.Fatalf("nil Stat must be empty so a flag-down PSTAT is unchanged, got %q", s)
	}
	if d, qb, nom, adm, aged, ovf, un, nr, ref := lit.Stats(); d|qb != 0 ||
		nom|adm|aged|ovf|un|nr|ref != 0 {
		t.Fatal("nil Stats must be all zero")
	}
}

// ---------------------------------------------------------------------------
// NOMINATION RULE, AND WHERE THE CLASS COMES FROM
// ---------------------------------------------------------------------------

// THE ANTI-REGEXP ASSERTION. The class is a FACT, matched exactly against the
// AGG_PATHS entries, and no interface name is parsed. The device the deleted
// '^(usb|wwan|rmnet)' guess would have called metered is STEADY here, and the
// one '^eth' would have called wired is SPOTTY, purely because AGG_SPOTTY says
// so. If anyone ever puts a name rule back in this file, this test fails.
func TestLightningClassComesFromTheFactNotTheName(t *testing.T) {
	t.Setenv("AGG_LIGHTNING", "1")
	t.Setenv("AGG_SPOTTY", "eth0")
	devs := []string{"usb0", "eth0"}
	c := litLinks(devs, litSocks(2))
	lit := NewLightning(c, devs)
	if lit == nil {
		t.Fatal("AGG_LIGHTNING=1 must build a Lightning")
	}
	if lit.spottyAt(0) {
		t.Fatal("usb0 must be STEADY: the fact does not name it, and no name rule exists")
	}
	if !lit.spottyAt(1) {
		t.Fatal("eth0 must be SPOTTY: the fact names it")
	}
}

// An AGG_SPOTTY entry that matches no source classifies nothing and does not
// stop the daemon: a source can leave the set between the fact being written and
// the daemon starting.
func TestLightningUnknownSpottyNameClassifiesNothing(t *testing.T) {
	t.Setenv("AGG_LIGHTNING", "1")
	t.Setenv("AGG_SPOTTY", "wwan0")
	devs := []string{"eth0", "usb0"}
	c := litLinks(devs, litSocks(2))
	lit := NewLightning(c, devs)
	if lit == nil {
		t.Fatal("must still build")
	}
	if lit.spottyAt(0) || lit.spottyAt(1) {
		t.Fatal("a name that matches no source must classify nothing")
	}
}

// An empty fact is the plumbing gap that exists today (build_agg_env emits no
// AGG_SPOTTY). It must be INERT, not a guess.
func TestLightningEmptyFactNominatesNothing(t *testing.T) {
	t.Setenv("AGG_LIGHTNING", "1")
	t.Setenv("AGG_SPOTTY", "")
	devs := []string{"eth0", "usb0"}
	c := litLinks(devs, litSocks(2))
	lit := NewLightning(c, devs)
	lit.Nominate(c.Links[1], litFrame(1, 100), time.Now())
	if _, _, nom, _, _, _, _, _, _ := lit.Stats(); nom != 0 {
		t.Fatalf("empty class fact must nominate nothing, got %d", nom)
	}
}

// STANDING: no trigger, no threshold, no health signal. 100 native sends on a
// spotty link produce 100 copies, the first one included.
func TestLightningNominatesEverySpottyFrame(t *testing.T) {
	c := litLinks([]string{"a", "b"}, litSocks(2))
	lit := litFor(c, []bool{true, false})
	now := time.Now()
	for i := 0; i < 100; i++ {
		lit.Nominate(c.Links[0], litFrame(uint32(i), 100), now)
	}
	d, _, nom, _, _, _, _, _, _ := lit.Stats()
	if nom != 100 || d != 100 {
		t.Fatalf("standing nomination: want 100 nominated / depth 100, got %d / %d", nom, d)
	}
}

// A native on a STEADY link nominates nothing: the rule is class identity.
func TestLightningDoesNotNominateOnSteadyLinks(t *testing.T) {
	c := litLinks([]string{"a", "b"}, litSocks(2))
	lit := litFor(c, []bool{true, false})
	for i := 0; i < 20; i++ {
		lit.Nominate(c.Links[1], litFrame(uint32(i), 100), time.Now())
	}
	if d, _, nom, _, _, _, _, _, _ := lit.Stats(); nom != 0 || d != 0 {
		t.Fatalf("steady link must nominate nothing, got nom=%d depth=%d", nom, d)
	}
}

// DEGENERATE 1 -- all-steady. No at-risk source, so nothing is ever nominated.
func TestLightningAllSteadyIsInert(t *testing.T) {
	c := litLinks([]string{"a", "b", "c"}, litSocks(3))
	lit := litFor(c, []bool{false, false, false})
	if lit.armed() {
		t.Fatal("all-steady must not be armed")
	}
	for i := range c.Links {
		lit.Nominate(c.Links[i], litFrame(uint32(i), 100), time.Now())
	}
	if d, _, nom, _, _, _, _, _, _ := lit.Stats(); nom != 0 || d != 0 {
		t.Fatalf("all-steady: want inert, got nom=%d depth=%d", nom, d)
	}
}

// DEGENERATE 2 -- all-spotty. There is no host, so nothing is nominated and
// nothing can be admitted: the design's "honest loss == pull".
func TestLightningAllSpottyAdmitsNothing(t *testing.T) {
	c := litLinks([]string{"a", "b"}, litSocks(2))
	lit := litFor(c, []bool{true, true})
	if lit.armed() {
		t.Fatal("all-spotty must not be armed: no host exists")
	}
	for i := 0; i < 10; i++ {
		lit.Nominate(c.Links[0], litFrame(uint32(i), 100), time.Now())
	}
	d, _, nom, _, _, _, un, _, _ := lit.Stats()
	if nom != 0 || d != 0 || un != 10 {
		t.Fatalf("all-spotty: want nom=0 depth=0 unarmed=10, got %d %d %d", nom, d, un)
	}
	if fr, ok := lit.Take(c.Links[1], time.Now()); ok || fr != nil {
		t.Fatal("a spotty link must never host a copy")
	}
}

// A link that can never send (no socket) is neither a source nor a host, so a
// box whose only steady link is disabled is not armed.
func TestLightningDisabledLinkIsNeitherSourceNorHost(t *testing.T) {
	c := &PullCore{FIFO: NewPullFIFO()}
	c.Links = append(c.Links, newPullLinkSock(0, "a", newFakeSock(0), testDst()))
	c.Links = append(c.Links, NewPullLink(1, "b", nil, testDst())) // no socket
	lit := litFor(c, []bool{true, false})
	if lit.armed() {
		t.Fatal("a link with no socket cannot host, so this must not be armed")
	}
}

// ---------------------------------------------------------------------------
// ADMISSION: ONE COPY, NEVER ON THE ORIGIN, ONLY THROUGH room()
// ---------------------------------------------------------------------------

// Exactly ONE copy per nominated frame. This is the precondition the peer's
// seq-keyed first-wins rests on.
func TestLightningOneCopyPerSeq(t *testing.T) {
	c := litLinks([]string{"a", "b"}, litSocks(2))
	lit := litFor(c, []bool{true, false})
	lit.Nominate(c.Links[0], litFrame(7, 100), time.Now())
	fr, ok := lit.Take(c.Links[1], time.Now())
	if !ok || fr == nil || fr.seq != 7 {
		t.Fatalf("first Take must yield the copy of seq 7, got %v ok=%v", fr, ok)
	}
	if fr2, ok2 := lit.Take(c.Links[1], time.Now()); ok2 {
		t.Fatalf("a second copy of the same nomination must not exist, got seq %d", fr2.seq)
	}
}

// A copy never rides the link that carried its original. With a consistent class
// fact that is implied by "a spotty link is never a host"; here the fact is made
// to contradict itself so the explicit guard is the only thing left standing.
func TestLightningCopyNeverRidesOrigin(t *testing.T) {
	c := litLinks([]string{"a", "b"}, litSocks(2))
	// Both classified STEADY, but the copy is recorded as having come from
	// link 0 -- the contradictory case the guard exists for.
	lit := litFor(c, []bool{false, false})
	lit.mu.Lock()
	cp := litFrame(9, 100)
	lit.pushBack(litCopy{fr: cp, src: 0})
	lit.bytes += wireBytes(cp)
	lit.nominated++
	lit.mu.Unlock()
	if fr, ok := lit.Take(c.Links[0], time.Now()); ok {
		t.Fatalf("link 0 carried the original; it must not get the copy (got seq %d)", fr.seq)
	}
	if _, _, _, _, _, ovf, _, _, _ := lit.Stats(); ovf != 1 {
		t.Fatal("the contradictory copy must be SHED, not left at the head to block the queue")
	}
}

// room() shut admits nothing and says so in its own counter.
func TestLightningRoomGateShutAdmitsNothing(t *testing.T) {
	c := litLinks([]string{"a", "b"}, litSocks(2))
	lit := litFor(c, []bool{true, false})
	lit.SetRoom(func(*PullLink) bool { return false })
	lit.Nominate(c.Links[0], litFrame(1, 100), time.Now())
	if _, ok := lit.Take(c.Links[1], time.Now()); ok {
		t.Fatal("room() shut must admit nothing")
	}
	if _, _, _, _, _, _, _, nr, _ := lit.Stats(); nr != 1 {
		t.Fatal("a host turned away by room() must be counted")
	}
}

// room() open admits, and the default (nil) behaves as open -- the socket is the
// gate, which is E2a's substitution and not a new predictor.
func TestLightningRoomGateOpenAndNilBothAdmit(t *testing.T) {
	for _, name := range []string{"nil", "open"} {
		c := litLinks([]string{"a", "b"}, litSocks(2))
		lit := litFor(c, []bool{true, false})
		if name == "open" {
			lit.SetRoom(func(*PullLink) bool { return true })
		}
		lit.Nominate(c.Links[0], litFrame(3, 100), time.Now())
		if _, ok := lit.Take(c.Links[1], time.Now()); !ok {
			t.Fatalf("room=%s must admit", name)
		}
	}
}

// ---------------------------------------------------------------------------
// THE POOL BOUND
// ---------------------------------------------------------------------------

// A copy contributes ZERO bytes to the native pool, so it cannot move either
// limb of U7's bound.
func TestLightningCopyAddsNothingToPoolBytes(t *testing.T) {
	c := litLinks([]string{"a", "b"}, litSocks(2))
	lit := litFor(c, []bool{true, false})
	now := time.Now()
	for i := 0; i < 20; i++ {
		c.FIFO.Enqueue(make([]byte, 500), now)
	}
	b0, pk0, mx0, qd0, rq0 := c.FIFO.ByteStats()
	for i := 0; i < 20; i++ {
		lit.Nominate(c.Links[0], litFrame(uint32(i), 500), now)
	}
	b1, pk1, mx1, qd1, rq1 := c.FIFO.ByteStats()
	if b0 != b1 || pk0 != pk1 || mx0 != mx1 || qd0 != qd1 || rq0 != rq1 {
		t.Fatalf("nomination must not touch the native pool: bytes %d->%d peak %d->%d "+
			"max %d->%d qdrops %d->%d retq %d->%d", b0, b1, pk0, pk1, mx0, mx1, qd0, qd1, rq0, rq1)
	}
	if d, _, _, _, _ := c.FIFO.Stats(); d != 20 {
		t.Fatalf("native depth must be untouched, got %d", d)
	}
}

// With the pool's byte limb ARMED and the pool full, nominating copies still
// sheds nothing: the copies are not in the pool, so they cannot evict a native.
func TestLightningCopiesCannotEvictNatives(t *testing.T) {
	c := litLinks([]string{"a", "b"}, litSocks(2))
	lit := litFor(c, []bool{true, false})
	now := time.Now()
	// 10 frames of 500 payload bytes; bound them exactly.
	for i := 0; i < 10; i++ {
		c.FIFO.Enqueue(make([]byte, 500), now)
	}
	full, _, _, _, _ := c.FIFO.ByteStats()
	c.FIFO.SetMaxBytes(full)
	if _, _, _, qd, _ := c.FIFO.ByteStats(); qd != 0 {
		t.Fatalf("precondition: the pool must start at the bound with no drops, got %d", qd)
	}
	for i := 0; i < 200; i++ {
		lit.Nominate(c.Links[0], litFrame(uint32(i), 1400), now)
	}
	b, _, _, qd, _ := c.FIFO.ByteStats()
	d, _, _, _, stale := c.FIFO.Stats()
	if qd != 0 || stale != 0 || d != 10 || b != full {
		t.Fatalf("200 copies against a full pool must shed no native: depth=%d bytes=%d "+
			"qdrops=%d stale=%d", d, b, qd, stale)
	}
}

// End to end: after a spotty link places a native, the pool is EMPTY and the
// copy exists. It shows the copy is built from a frame the pool has already
// released; it does NOT by itself prove the ordering inside the loop, which is
// carried by the single call site (DriveLit's sendOK arm).
func TestLightningNominatesOnlyAfterTheNativeLeftThePool(t *testing.T) {
	c := litLinks([]string{"a", "b"}, litSocks(2))
	lit := litFor(c, []bool{true, false})
	defer c.FIFO.Close()
	c.FIFO.Enqueue(make([]byte, 200), time.Now())
	go c.Links[0].DriveLit(c.FIFO, lit)
	ok := waitFor(func() bool {
		_, _, nom, _, _, _, _, _, _ := lit.Stats()
		return nom == 1
	}, 2*time.Second)
	if !ok {
		t.Fatal("the native send must nominate exactly one copy")
	}
	if d, _, _, _, _ := c.FIFO.Stats(); d != 0 {
		t.Fatalf("the original must already be out of the pool, depth=%d", d)
	}
}

// A copy CANNOT EVICT ITS OWN ORIGINAL, and the reason is structural, not
// arithmetic: Nominate is called only from DriveLit's `case sendOK:` arm,
// after Draw has already popped the frame out of the pool -- so the original
// is out before its copy can exist. This drives the real DriveLit loop (not a
// hand rebuild of its ordering) through a backpressure-then-success sequence
// on the SAME frame and inspects the pool between the two attempts, at a point
// where nothing but this goroutine's own f.Wake() call can advance the parked
// link -- so the check is deterministic, not a timing race: with txBackoff==0
// (the default; nothing here changes it) a refused link parks on
// f.WaitWork(), and only Wake/Progress/Close release it, none of which fire on
// their own in this test.
//
// It discriminates. Moving `lit.Nominate(l, fr, now)` out of the sendOK arm to
// run unconditionally after the switch -- the "obvious simplification" that
// reasons "Draw already popped the frame, so nomination is always safe" -- was
// built and run against this tree on CI (bond-ci run 33324199573, job id
// 99291349483, u15b-lightning): the mutant FAILS this test, at "the successful
// retry must nominate exactly one copy" (lightning_test.go:453 at the time).
// Mechanism: backoff() blocks inside the sendBackpressure case, so the mutant's
// unconditional Nominate call is not reached until this test's own f.Wake()
// unparks it -- at which point it fires for the ALREADY-RETURNED original
// (now back at depth 1), and the loop's next pass draws that SAME frame again,
// sends it successfully, and the mutant fires Nominate on it A SECOND TIME. So
// nominated jumps 0 -> 1 -> 2 for one native frame, past the exact value 1
// this test's waitFor holds it to, and the wait times out. Reverted before
// commit; the real code (Nominate only in the sendOK arm) passed on the
// unmutated tree, same branch, run 33323545838 job id 99289588169, in 0.02s.
func TestLightningNominationHappensAfterTheOriginalHasLeftThePool(t *testing.T) {
	socks := litSocks(2)
	socks[0] = newFakeSock(0, syscall.ENOBUFS, nil) // 1st write refused, 2nd succeeds
	c := litLinks([]string{"a", "b"}, socks)
	// link 0 is the spotty drawer/source; link 1 is the steady host armed()
	// needs to exist (Nominate is a no-op with no eligible host).
	lit := litFor(c, []bool{true, false})
	defer c.FIFO.Close()
	c.FIFO.Enqueue(make([]byte, 100), time.Now())

	go c.Links[0].DriveLit(c.FIFO, lit)

	if !waitFor(func() bool { return socks[0].tries() >= 1 }, 2*time.Second) {
		t.Fatal("link 0 never attempted the first write")
	}
	if !waitFor(func() bool {
		d, _, _, _, _ := c.FIFO.Stats()
		return d == 1
	}, 2*time.Second) {
		t.Fatal("a refused native must be Returned to the pool")
	}
	// The link is now parked in backoff()'s f.WaitWork() -- nothing else in
	// this test calls Wake/Progress/Close, so it stays parked until we release
	// it below. The state is therefore stable, not merely sampled early.
	time.Sleep(20 * time.Millisecond)
	if _, _, nom, _, _, _, _, _, _ := lit.Stats(); nom != 0 {
		t.Fatalf("must not have nominated while the original sits back in the "+
			"pool (refused, not sent): got nom=%d", nom)
	}
	if d, _, _, _, _ := c.FIFO.Stats(); d != 1 {
		t.Fatal("precondition broken: the original left the pool between the two checks")
	}

	c.FIFO.Wake() // the only thing that can release the parked link
	if !waitFor(func() bool {
		_, _, nom, _, _, _, _, _, _ := lit.Stats()
		return nom == 1
	}, 2*time.Second) {
		t.Fatal("the successful retry must nominate exactly one copy")
	}
	if d, _, _, _, _ := c.FIFO.Stats(); d != 0 {
		t.Fatalf("once nominated, the original must already be gone from the pool, depth=%d", d)
	}
}

// ---------------------------------------------------------------------------
// THE TWO LIMBS OF THE COPY QUEUE
// ---------------------------------------------------------------------------

// The TTL limb is the design's own bound: a copy older than the reorder hold is
// shed, oldest first.
func TestLightningTTLShedsOldestCopiesFirst(t *testing.T) {
	c := litLinks([]string{"a", "b"}, litSocks(2))
	lit := litFor(c, []bool{true, false})
	base := time.Now()
	for i := 0; i < 5; i++ {
		lit.Nominate(c.Links[0], litFrame(uint32(i), 100), base.Add(time.Duration(i)*10*time.Millisecond))
	}
	// hold = 25ms, evaluated 45ms after the first nomination: copies stamped at
	// +0, +10 are older than 25ms; +20, +30, +40 are not.
	lit.Tick(base.Add(45*time.Millisecond), 25*time.Millisecond)
	d, _, _, _, aged, _, _, _, _ := lit.Stats()
	if aged != 2 || d != 3 {
		t.Fatalf("TTL limb: want 2 aged / 3 left, got %d / %d", aged, d)
	}
	fr, ok := lit.Take(c.Links[1], base.Add(45*time.Millisecond))
	if !ok || fr.seq != 2 {
		t.Fatalf("the oldest SURVIVING copy must be next, want seq 2, got %v ok=%v", fr, ok)
	}
}

// The byte limb sheds down to and including the last copy -- the deliberate
// difference from the native pool, which keeps one frame.
func TestLightningByteLimbShedsEvenTheLastCopy(t *testing.T) {
	c := litLinks([]string{"a", "b"}, litSocks(2))
	lit := litFor(c, []bool{true, false})
	lit.maxBytes = 1 // smaller than any frame
	lit.Nominate(c.Links[0], litFrame(1, 100), time.Now())
	d, qb, _, _, _, ovf, _, _, _ := lit.Stats()
	if d != 0 || qb != 0 || ovf != 1 {
		t.Fatalf("byte limb must shed the only copy: depth=%d bytes=%d ovf=%d", d, qb, ovf)
	}
}

// The byte limb sheds OLDEST first, like the native pool's.
func TestLightningByteLimbShedsOldestFirst(t *testing.T) {
	c := litLinks([]string{"a", "b"}, litSocks(2))
	lit := litFor(c, []bool{true, false})
	now := time.Now()
	// Room for exactly two frames of this size.
	lit.maxBytes = 2 * (100 + HdrLen)
	for i := 0; i < 3; i++ {
		lit.Nominate(c.Links[0], litFrame(uint32(i), 100), now)
	}
	d, _, _, _, _, ovf, _, _, _ := lit.Stats()
	if d != 2 || ovf != 1 {
		t.Fatalf("want depth 2 / 1 overflowed, got %d / %d", d, ovf)
	}
	fr, ok := lit.Take(c.Links[1], now)
	if !ok || fr.seq != 1 {
		t.Fatalf("the OLDEST (seq 0) must have been shed, so seq 1 is next; got %v ok=%v", fr, ok)
	}
}

// ---------------------------------------------------------------------------
// NATIVE-FIRST, AND WHAT A REFUSED COPY COSTS
// ---------------------------------------------------------------------------

// NATIVE-FIRST. A host with native work queued sends ALL of it before it touches
// a copy. Asserted on the wire order, not on counters.
func TestLightningNativeFirst(t *testing.T) {
	socks := litSocks(2)
	c := litLinks([]string{"a", "b"}, socks)
	lit := litFor(c, []bool{true, false})
	defer c.FIFO.Close()
	now := time.Now()
	for i := 0; i < 5; i++ {
		lit.Nominate(c.Links[0], litFrame(uint32(1000+i), 100), now)
	}
	for i := 0; i < 50; i++ {
		c.FIFO.Enqueue(make([]byte, 100), now)
	}
	go c.Links[1].DriveLit(c.FIFO, lit)
	if !waitFor(func() bool { return socks[1].tries() >= 55 }, 5*time.Second) {
		t.Fatalf("expected 50 natives + 5 copies on the host, got %d writes", socks[1].tries())
	}
	seqs := seqsOf(t, socks[1].frames())[:55]
	for i, s := range seqs {
		if i < 50 && s >= 1000 {
			t.Fatalf("a copy (seq %d) was sent at position %d, before the native pool "+
				"was drained: native-first is broken", s, i)
		}
		if i >= 50 && s < 1000 {
			t.Fatalf("position %d carries native seq %d after the pool should be empty", i, s)
		}
	}
}

// A refused copy is SHED: it is not requeued, not returned to the native pool,
// and the host does not park on it.
func TestLightningRefusedCopyIsShedNotRequeued(t *testing.T) {
	socks := litSocks(2)
	socks[1] = newFakeSock(0, syscall.ENOBUFS)
	c := litLinks([]string{"a", "b"}, socks)
	lit := litFor(c, []bool{true, false})
	defer c.FIFO.Close()
	now := time.Now()
	lit.Nominate(c.Links[0], litFrame(42, 100), now)
	go c.Links[1].DriveLit(c.FIFO, lit)
	if !waitFor(func() bool {
		_, _, _, _, _, _, _, _, ref := lit.Stats()
		return ref >= 1
	}, 2*time.Second) {
		t.Fatal("the refused copy must be counted")
	}
	d, _, _, adm, _, _, _, _, _ := lit.Stats()
	if d != 0 || adm != 0 {
		t.Fatalf("a refused copy must be shed, not requeued: depth=%d admitted=%d", d, adm)
	}
	if _, _, _, _, retq := c.FIFO.ByteStats(); retq != 0 {
		t.Fatalf("a copy must never be Returned to the NATIVE pool, retq=%d", retq)
	}
}

// A copy refusal must not stop the host from doing native work: the host is not
// parked, so a native enqueued afterwards still goes out.
func TestLightningCopyRefusalDoesNotParkTheHost(t *testing.T) {
	socks := litSocks(2)
	// First write (the copy) is refused; everything after succeeds.
	socks[1] = newFakeSock(0, syscall.ENOBUFS, nil)
	c := litLinks([]string{"a", "b"}, socks)
	lit := litFor(c, []bool{true, false})
	defer c.FIFO.Close()
	stop := tickWake(c.FIFO)
	defer stop()
	lit.Nominate(c.Links[0], litFrame(42, 100), time.Now())
	go c.Links[1].DriveLit(c.FIFO, lit)
	if !waitFor(func() bool {
		_, _, _, _, _, _, _, _, ref := lit.Stats()
		return ref >= 1
	}, 2*time.Second) {
		t.Fatal("the copy must be refused first")
	}
	c.FIFO.Enqueue(make([]byte, 100), time.Now())
	if !waitFor(func() bool { return c.Links[1].Sent() >= 1 }, 2*time.Second) {
		t.Fatal("the host must still carry native work after a copy refusal")
	}
}

// ---------------------------------------------------------------------------
// WHAT THE COPY LOOKS LIKE ON THE WIRE -- the precondition for peer first-wins
// ---------------------------------------------------------------------------

// The copy carries the ORIGINAL's seq and the HOST's pathID, as a plain data
// frame. The seq is what makes the peer ring dedupe it; the pathID is what keeps
// the peer's per-link accounting attributed to the link that actually carried it.
func TestLightningCopyCarriesOriginalSeqAndHostPathID(t *testing.T) {
	socks := litSocks(2)
	c := litLinks([]string{"a", "b"}, socks)
	lit := litFor(c, []bool{true, false})
	lit.Nominate(c.Links[0], litFrame(4242, 100), time.Now())
	fr, ok := lit.Take(c.Links[1], time.Now())
	if !ok {
		t.Fatal("host must take the copy")
	}
	out := make([]byte, MaxPayload+HdrLen)
	if r := c.Links[1].send(fr, out); r != sendOK {
		t.Fatalf("copy send: %v", r)
	}
	w := socks[1].frames()
	if len(w) != 1 {
		t.Fatalf("want one write, got %d", len(w))
	}
	fl, pid, sq, _, fseq, _, err := Unpack(w[0].b)
	if err != nil {
		t.Fatalf("unpack: %v", err)
	}
	if fl != FlagData {
		t.Fatalf("a copy is an ordinary DATA frame, got flags %#x", fl)
	}
	if sq != 4242 {
		t.Fatalf("copy must carry the ORIGINAL seq 4242, got %d", sq)
	}
	if pid != 1 {
		t.Fatalf("copy must carry the HOST pathID 1, got %d", pid)
	}
	if fseq != 0 {
		t.Fatalf("copy must consume the host's own fseq series, want 0, got %d", fseq)
	}
}

// A copy consumes the host link's fseq exactly like a native, because to the
// peer's per-link loss meter it IS one. That is also why litsent is printed:
// PullLink.Sent() mixes the two and only litsent recovers the split.
func TestLightningCopyConsumesTheHostFseqAndIsCountedSeparately(t *testing.T) {
	socks := litSocks(2)
	c := litLinks([]string{"a", "b"}, socks)
	lit := litFor(c, []bool{true, false})
	out := make([]byte, MaxPayload+HdrLen)
	for i := 0; i < 2; i++ {
		lit.Nominate(c.Links[0], litFrame(uint32(500+i), 100), time.Now())
		fr, ok := lit.Take(c.Links[1], time.Now())
		if !ok {
			t.Fatalf("copy %d not taken", i)
		}
		if r := c.Links[1].send(fr, out); r != sendOK {
			t.Fatalf("copy %d send: %v", i, r)
		}
		lit.Sent(c.Links[1])
	}
	for i, w := range socks[1].frames() {
		_, _, _, _, fseq, _, err := Unpack(w.b)
		if err != nil {
			t.Fatalf("unpack %d: %v", i, err)
		}
		if fseq != uint32(i) {
			t.Fatalf("write %d: want fseq %d, got %d", i, i, fseq)
		}
	}
	if c.Links[1].Sent() != 2 {
		t.Fatalf("the link counter counts copies too, want 2, got %d", c.Links[1].Sent())
	}
	lit.mu.Lock()
	per := lit.perLink[1]
	lit.mu.Unlock()
	if per != 2 {
		t.Fatalf("litsent must attribute both copies to link 1, got %d", per)
	}
}

// ---------------------------------------------------------------------------
// N-GENERICITY
// ---------------------------------------------------------------------------

// N enters as len(Links) and nowhere else. For every N the LAST link is the only
// steady one, so every spotty link's nomination must reach it. N=1 is the
// all-spotty degenerate and must admit nothing.
func TestLightningIsNGeneric(t *testing.T) {
	for _, n := range []int{1, 2, 3, 5, 8} {
		names := make([]string, n)
		spotty := make([]bool, n)
		for i := 0; i < n; i++ {
			names[i] = string(rune('a' + i))
			spotty[i] = i < n-1
		}
		if n == 1 {
			spotty[0] = true // the all-spotty degenerate
		}
		c := litLinks(names, litSocks(n))
		lit := litFor(c, spotty)
		nsp := 0
		for i := range spotty {
			if spotty[i] {
				nsp++
				lit.Nominate(c.Links[i], litFrame(uint32(i), 100), time.Now())
			}
		}
		wantNom := nsp
		if n == 1 {
			wantNom = 0 // not armed: no host
		}
		if _, _, nom, _, _, _, _, _, _ := lit.Stats(); nom != uint64(wantNom) {
			t.Fatalf("N=%d: want %d nominated, got %d", n, wantNom, nom)
		}
		got := 0
		for {
			if _, ok := lit.Take(c.Links[n-1], time.Now()); !ok {
				break
			}
			got++
		}
		if got != wantNom {
			t.Fatalf("N=%d: the steady link must be able to host all %d copies, took %d",
				n, wantNom, got)
		}
	}
}

// No index is privileged: moving WHICH links are spotty moves the counts with
// them and changes nothing else.
func TestLightningIsPermutationSymmetric(t *testing.T) {
	run := func(spotty []bool) (uint64, int) {
		c := litLinks([]string{"a", "b", "c", "d"}, litSocks(4))
		lit := litFor(c, spotty)
		for i := range spotty {
			if spotty[i] {
				lit.Nominate(c.Links[i], litFrame(uint32(i), 100), time.Now())
			}
		}
		_, _, nom, _, _, _, _, _, _ := lit.Stats()
		host := -1
		for i := range spotty {
			if !spotty[i] {
				host = i
				break
			}
		}
		took := 0
		for {
			if _, ok := lit.Take(c.Links[host], time.Now()); !ok {
				break
			}
			took++
		}
		return nom, took
	}
	n1, t1 := run([]bool{true, true, false, false})
	n2, t2 := run([]bool{false, false, true, true})
	if n1 != n2 || t1 != t2 {
		t.Fatalf("permuting the class vector changed the result: %d/%d vs %d/%d",
			n1, t1, n2, t2)
	}
}

// ---------------------------------------------------------------------------
// PSTAT
// ---------------------------------------------------------------------------

// The stat fragment carries every counter, including refused -- the one that
// makes E1's BlockedMs contamination visible after the fact.
func TestLightningStatCarriesTheRefusedCounter(t *testing.T) {
	c := litLinks([]string{"a", "b"}, litSocks(2))
	lit := litFor(c, []bool{true, false})
	lit.Refused()
	s := lit.Stat()
	for _, want := range []string{"LIT ", "nom=", "adm=", "aged=", "ovf=", "unarmed=",
		"noroom=", "refused=1", "litsent="} {
		if !strings.Contains(s, want) {
			t.Fatalf("PSTAT fragment %q is missing %q", s, want)
		}
	}
}
