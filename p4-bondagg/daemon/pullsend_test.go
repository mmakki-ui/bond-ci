package main

import (
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// THE SEAM, and the tests that execute the ENOBUFS remediation END TO END.
//
// Before linkSocket existed, PullLink held a concrete *net.UDPConn, so NOTHING
// in this package could call Drive, send or backoff. What was tested was
// classifySend -- a pure errno->enum function -- and Return() accounting in
// isolation. Every COMPOSED claim was unasserted: that a refusal charges blocked
// time, that a refusal does not burn an fseq, that Drive returns the frame
// rather than dropping it, that a refusing link does not starve a healthy one,
// and that a permanently refusing link does not spin. Those are the claims that
// matter on hardware, and they are the ones below.
// ---------------------------------------------------------------------------

// fakeSock is the injected socket. It returns a caller-chosen sequence of write
// outcomes -- the LAST entry repeats forever -- optionally after a delay, and it
// records the exact bytes handed to it so the wire fields can be asserted.
type fakeSock struct {
	mu       sync.Mutex
	outcomes []error
	attempts int
	writes   []fakeWrite
	delay    time.Duration
}

type fakeWrite struct {
	b   []byte
	err error
}

func newFakeSock(delay time.Duration, outcomes ...error) *fakeSock {
	if len(outcomes) == 0 {
		outcomes = []error{nil}
	}
	return &fakeSock{outcomes: outcomes, delay: delay}
}

func (s *fakeSock) WriteToUDP(b []byte, _ *net.UDPAddr) (int, error) {
	s.mu.Lock()
	i := s.attempts
	if i >= len(s.outcomes) {
		i = len(s.outcomes) - 1
	}
	err := s.outcomes[i]
	s.attempts++
	cp := make([]byte, len(b))
	copy(cp, b)
	s.writes = append(s.writes, fakeWrite{b: cp, err: err})
	d := s.delay
	s.mu.Unlock()
	if d > 0 {
		time.Sleep(d)
	}
	if err != nil {
		return 0, err
	}
	return len(b), nil
}

// SyscallConn is in the seam so that a link with no real fd is a nil INTERFACE
// rather than a typed-nil *net.UDPConn. A fake has no fd; SndBuf must report -1.
func (s *fakeSock) SyscallConn() (syscall.RawConn, error) {
	return nil, errors.New("fake socket has no file descriptor")
}

func (s *fakeSock) tries() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.attempts
}

func (s *fakeSock) frames() []fakeWrite {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]fakeWrite, len(s.writes))
	copy(out, s.writes)
	return out
}

func testDst() *net.UDPAddr { return &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1} }

// tickWake mimics the control goroutine's Wake cadence, which is the worst-case
// wakeup for a link parked after a refusal.
func tickWake(f *PullFIFO) func() {
	stop := make(chan struct{})
	go func() {
		t := time.NewTicker(2 * time.Millisecond)
		defer t.Stop()
		for {
			select {
			case <-stop:
				return
			case <-t.C:
				f.Wake()
			}
		}
	}()
	return func() { close(stop) }
}

func waitFor(cond func() bool, d time.Duration) bool {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return true
		}
		time.Sleep(time.Millisecond)
	}
	return cond()
}

// A refused write must NOT consume an fseq. The peer's loss meter reads a gap in
// fseq as a LOSS, so burning one on local backpressure manufactures peer-visible
// per-path loss out of a condition that lost nothing. Previously this was
// "correct by inspection" (the increment sits after the switch) and nothing
// executed it.
func TestPullSendRefusalDoesNotBurnFseq(t *testing.T) {
	fs := newFakeSock(0, wrapErrno(syscall.ENOBUFS), wrapErrno(syscall.ENOBUFS), nil)
	l := newPullLinkSock(3, "if3", fs, testDst())
	out := make([]byte, MaxPayload+HdrLen)

	for i := 0; i < 2; i++ {
		fr := &PullFrame{seq: 42, enq: time.Now(), payload: []byte{1, 2, 3}}
		if r := l.send(fr, out); r != sendBackpressure {
			t.Fatalf("attempt %d: send=%d, want sendBackpressure", i, r)
		}
	}
	for i := 0; i < 2; i++ {
		fr := &PullFrame{seq: uint32(42 + i), enq: time.Now(), payload: []byte{1, 2, 3}}
		if r := l.send(fr, out); r != sendOK {
			t.Fatalf("success attempt %d: send=%d, want sendOK", i, r)
		}
	}

	w := fs.frames()
	if len(w) != 4 {
		t.Fatalf("socket saw %d writes, want 4", len(w))
	}
	// Two refusals then two successes: the fseq series the peer sees must be
	// 0,1 with no gap, and the refused attempts must have re-offered fseq 0.
	wantFseq := []uint32{0, 0, 0, 1}
	wantSeq := []uint32{42, 42, 42, 43}
	for i, fw := range w {
		fl, pid, sq, _, fq, _, err := Unpack(fw.b)
		if err != nil {
			t.Fatalf("attempt %d: frame does not unpack: %v", i, err)
		}
		if fl != FlagData {
			t.Fatalf("attempt %d: flags=%d, want FlagData", i, fl)
		}
		if pid != 3 {
			t.Fatalf("attempt %d: pathID=%d, want 3 (the link index, nothing else)", i, pid)
		}
		if fq != wantFseq[i] {
			t.Fatalf("attempt %d: fseq=%d, want %d -- a refusal burned a sub-sequence "+
				"number and would show at the peer as fabricated per-path loss", i, fq, wantFseq[i])
		}
		if sq != wantSeq[i] {
			t.Fatalf("attempt %d: seq=%d, want %d", i, sq, wantSeq[i])
		}
	}
	if l.Sent() != 2 || l.Bpress() != 2 || l.Errs() != 0 {
		t.Fatalf("sent=%d bpress=%d errs=%d, want 2/2/0", l.Sent(), l.Bpress(), l.Errs())
	}
}

// BLOCKER 1, the counter split. A SUCCESSFUL write must charge nothing to
// BlockedMs: the previous revision charged every write unconditionally while
// declaring BlockedMs to be the time the link was "unable to place a frame", so
// a mid-limited link accumulated a throughput-proportional floor that reads like
// mild edge blocking. E1's discriminator would have read a confident wrong
// answer off it.
func TestPullSendSuccessChargesWriteTimeNotBlockedTime(t *testing.T) {
	const d = 20 * time.Millisecond
	fs := newFakeSock(d, nil)
	l := newPullLinkSock(0, "if0", fs, testDst())
	out := make([]byte, MaxPayload+HdrLen)
	fr := &PullFrame{seq: 1, enq: time.Now(), payload: []byte{7}}

	if r := l.send(fr, out); r != sendOK {
		t.Fatalf("send=%d, want sendOK", r)
	}
	if got := l.BlockedMs(); got != 0 {
		t.Fatalf("BlockedMs=%dms after a SUCCESSFUL write, want 0: a successful sendto "+
			"is neither unable nor blocked, and charging it gives every link a "+
			"throughput-proportional floor", got)
	}
	if got := l.WriteNs(); got < int64(d/2) {
		t.Fatalf("WriteNs=%dns, want >= %dns (the write really did take that long)", got, int64(d/2))
	}
	if got := l.WriteFloorNs(); got <= 0 || got > l.WriteNs() {
		t.Fatalf("WriteFloorNs=%dns, want 0 < floor <= WriteNs=%dns", got, l.WriteNs())
	}
}

// The other half of the split: a REFUSED write charges its whole duration to
// BlockedMs and nothing to WriteNs, and it does not count as sent.
func TestPullSendRefusalChargesBlockedTimeOnly(t *testing.T) {
	const d = 20 * time.Millisecond
	fs := newFakeSock(d, wrapErrno(syscall.ENOBUFS))
	l := newPullLinkSock(0, "if0", fs, testDst())
	out := make([]byte, MaxPayload+HdrLen)
	fr := &PullFrame{seq: 1, enq: time.Now(), payload: []byte{7}}

	if r := l.send(fr, out); r != sendBackpressure {
		t.Fatalf("send=%d, want sendBackpressure", r)
	}
	if got := l.BlockedMs(); got < int64(d/2/time.Millisecond) {
		t.Fatalf("BlockedMs=%dms, want >= %d", got, int64(d/2/time.Millisecond))
	}
	if got := l.WriteNs(); got != 0 {
		t.Fatalf("WriteNs=%dns after a refused write, want 0", got)
	}
	if got := l.WriteFloorNs(); got != -1 {
		t.Fatalf("WriteFloorNs=%d before any success, want -1 (unmeasured)", got)
	}
	if l.Sent() != 0 || l.Bytes() != 0 || l.Errs() != 0 || l.Bpress() != 1 {
		t.Fatalf("sent=%d bytes=%d errs=%d bpress=%d, want 0/0/0/1",
			l.Sent(), l.Bytes(), l.Errs(), l.Bpress())
	}
}

// A path-down write charges NEITHER counter and is not a backpressure event:
// BlockedMs must stay clean of failures retrying cannot fix.
func TestPullSendPathDownChargesNeitherClock(t *testing.T) {
	fs := newFakeSock(10*time.Millisecond, wrapErrno(syscall.ENETUNREACH))
	l := newPullLinkSock(0, "if0", fs, testDst())
	out := make([]byte, MaxPayload+HdrLen)
	fr := &PullFrame{seq: 1, enq: time.Now(), payload: []byte{7}}

	if r := l.send(fr, out); r != sendPathDown {
		t.Fatalf("send=%d, want sendPathDown", r)
	}
	if l.BlockedMs() != 0 || l.WriteNs() != 0 {
		t.Fatalf("blk=%dms wr=%dns after a path-down write, want 0/0", l.BlockedMs(), l.WriteNs())
	}
	if l.Errs() != 1 || l.Bpress() != 0 {
		t.Fatalf("errs=%d bpress=%d, want 1/0", l.Errs(), l.Bpress())
	}
}

// D1 END TO END, through Drive: a refusal must RETURN the frame to the pool and
// the link must place it on a later attempt. Nothing is dropped, and the frame
// that eventually goes out is the same seq.
func TestPullDriveReturnsRefusedFrameAndPlacesItLater(t *testing.T) {
	f := NewPullFIFO()
	fs := newFakeSock(0, wrapErrno(syscall.ENOBUFS), wrapErrno(syscall.ENOBUFS), nil)
	l := newPullLinkSock(0, "if0", fs, testDst())
	f.Enqueue([]byte{9, 9, 9}, time.Now())

	stop := tickWake(f)
	done := make(chan struct{})
	go func() { l.Drive(f); close(done) }()

	if !waitFor(func() bool { return l.Sent() == 1 }, 5*time.Second) {
		stop()
		t.Fatalf("frame never placed: sent=%d bpress=%d", l.Sent(), l.Bpress())
	}
	stop()
	f.Close()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Drive did not exit after Close")
	}

	if l.Bpress() != 2 {
		t.Fatalf("bpress=%d, want 2", l.Bpress())
	}
	depth, _, enq, drawn, stale := f.Stats()
	_, _, _, qdrops, retq := f.ByteStats()
	if depth != 0 || enq != 1 || drawn != 1 || stale != 0 || qdrops != 0 {
		t.Fatalf("depth=%d enq=%d drawn=%d stale=%d qdrop=%d, want 0/1/1/0/0",
			depth, enq, drawn, stale, qdrops)
	}
	if retq != 2 {
		t.Fatalf("retq=%d, want 2 -- each refusal is a rollback, not a drop", retq)
	}
	w := fs.frames()
	if len(w) != 3 {
		t.Fatalf("socket saw %d writes, want 3", len(w))
	}
	for i, fw := range w {
		_, _, sq, _, _, _, err := Unpack(fw.b)
		if err != nil || sq != 0 {
			t.Fatalf("attempt %d: seq=%d err=%v, want the same seq 0 every time", i, sq, err)
		}
	}
}

// THE WITNESS TEST for the round-4 wake-set defect, and the shape the previous
// version of it was missing.
//
// The previous version used ONE link -- the only N at which the file's own claim
// ("with every link refusing and the offer idle, the only wake is the control
// tick") was true. At N=1 a Return finds parked==0, so it Signals rather than
// Broadcasts and the link then parks on the post-increment generation. At N >= 2
// the same Return found the OTHER refuser parked and released it, so:
//
// A refuses, Returns (gen++, Broadcast wakes parked B), parks. B wakes, draws
// the same frame, refuses, Returns (gen++, wakes A), parks. Repeat, at CPU
// speed, with no external event anywhere on the path.
//
// Neither Drive's backpressure branch nor WaitWork sleeps, so that is a busy
// spin -- in exactly the regime this daemon is for: a dual-WAN router whose two
// qdiscs are both full, where the spinning goroutines contend with the softirq
// that has to drain them.
//
// So the test sweeps N. The whole draw set refuses forever, there is no tick, no
// further offer and no successful write anywhere, which means NOTHING in the
// system produces drain evidence. Each link may draw the one frame once and
// refuse once; total attempts must therefore not exceed N.
//
// BEFORE the wake-set fix this failed for every N >= 2 with attempt counts in
// the tens of thousands, and passed at N=1. AFTER it, attempts == N.
func TestPullDriveEveryLinkRefusingDoesNotSpinForAnyN(t *testing.T) {
	for _, n := range []int{1, 2, 3, 5} {
		f := NewPullFIFO()
		socks := make([]*fakeSock, n)
		var wg sync.WaitGroup
		for i := 0; i < n; i++ {
			socks[i] = newFakeSock(0, wrapErrno(syscall.ENOBUFS))
			l := newPullLinkSock(i, "if", socks[i], testDst())
			wg.Add(1)
			go func() { defer wg.Done(); l.Drive(f) }()
		}
		f.Enqueue([]byte{1}, time.Now())

		time.Sleep(100 * time.Millisecond)
		got := 0
		for _, s := range socks {
			got += s.tries()
		}
		f.Close()
		wg.Wait()

		if got > n {
			t.Fatalf("N=%d: %d write attempts in 100ms with no drain evidence anywhere "+
				"(no tick, no offer, no successful write): the draw set is SPINNING. "+
				"Each link may attempt the head frame once and must then park.", n, got)
		}
		if got == 0 {
			t.Fatalf("N=%d: no write attempted at all -- no link ever drew the frame", n)
		}
	}
}

// The pool-level wake set, asserted directly, one claim per test.
//
// parkRefusers returns once n waiters are provably parked: parked is bumped
// while WaitWork still HOLDS the pool mutex, so any pool call the test makes
// afterwards must wait for dcv.Wait to release that mutex. No sleep-and-hope.
func parkRefusers(t *testing.T, f *PullFIFO, n int) []chan struct{} {
	t.Helper()
	out := make([]chan struct{}, n)
	for i := range out {
		c := make(chan struct{})
		out[i] = c
		go func() { f.WaitWork(); close(c) }()
	}
	if !waitFor(func() bool { return atomic.LoadInt32(&f.parked) == int32(n) }, 2*time.Second) {
		t.Fatalf("only %d of %d waiters parked in WaitWork", atomic.LoadInt32(&f.parked), n)
	}
	return out
}

func parkRefuser(t *testing.T, f *PullFIFO) chan struct{} {
	t.Helper()
	return parkRefusers(t, f, 1)[0]
}

// parkDrawers is the cv-side twin: n goroutines provably parked in Draw's
// cv.Wait on an empty open pool, each reporting the ok value its Draw returns.
// drawParked is bumped under the pool mutex immediately before cv.Wait releases
// it, so the same ordering argument holds -- once this returns, a single pool
// call by the test is ordered after every waiter is registered on cv.
func parkDrawers(t *testing.T, f *PullFIFO, n int) chan bool {
	t.Helper()
	out := make(chan bool, n)
	for i := 0; i < n; i++ {
		go func() { _, ok := f.Draw(); out <- ok }()
	}
	if !waitFor(func() bool { return atomic.LoadInt32(&f.drawParked) == int32(n) }, 2*time.Second) {
		t.Fatalf("only %d of %d drawers parked in Draw", atomic.LoadInt32(&f.drawParked), n)
	}
	return out
}

// ---------------------------------------------------------------------------
// THE BROADCASTS, DISCRIMINATED. Every wake-set test above this line parks
// exactly ONE waiter, and one waiter cannot tell Broadcast from Signal: the
// FIRST THREE tests below are the only ones in the suite that fail if a
// Broadcast in pull.go is downgraded. Confirmed by flipping the code, not by
// reading it -- see the DRAIN WAKE SET block in pull.go.
//
// The shape is the same in those three: park a PAIR, fire ONE event, require
// BOTH releases. The FOURTH test is the INVERSE and is easy to misread as a
// duplicate: it fails on an UPGRADE, pinning that Enqueue wakes exactly one
// drawer, because one new frame is not evidence for two.
//
// One event releasing one waiter is not a defect the suite would
// notice anywhere else, and its cost is real -- N parked links re-evaluate over
// N control ticks instead of one, i.e. up to N*PingIval of idle device with work
// still in the pool.
// ---------------------------------------------------------------------------

// Progress -> dcv, the EVERY claim (pull.go drainLocked: "one device draining is
// evidence for every parked link"). ONE successful write on one link must
// release ALL parked refusers, not one per write.
func TestPullFIFOProgressReleasesEveryParkedRefuser(t *testing.T) {
	f := NewPullFIFO()
	defer f.Close()
	released := parkRefusers(t, f, 2)

	f.Progress() // exactly one drain event

	// parked is decremented inside WaitWork before it drops the pool mutex, so
	// parked == 0 is the exact "both left" condition and the count in the failure
	// message is the true residue rather than a loop index.
	if !waitFor(func() bool { return atomic.LoadInt32(&f.parked) == 0 }, 2*time.Second) {
		t.Fatalf("one Progress left %d of 2 refusers still parked. drainLocked claims one "+
			"device draining is evidence for EVERY parked link; with a Signal it is "+
			"evidence for one of them and the rest wait for the control tick",
			atomic.LoadInt32(&f.parked))
	}
	awaitAll(t, released, "Progress")
}

// awaitAll requires every parked waiter's goroutine to have actually returned,
// not merely to have been counted out of parked.
func awaitAll(t *testing.T, cs []chan struct{}, what string) {
	t.Helper()
	for i, c := range cs {
		select {
		case <-c:
		case <-time.After(2 * time.Second):
			t.Fatalf("%s: waiter %d left WaitWork but its goroutine never returned", what, i)
		}
	}
}

// Wake -> dcv, the WaitWork half of the control tick. The tick is the ONLY
// release a fully-refusing draw set ever gets, so if it releases one refuser per
// tick then N refusers retry over N ticks -- the worst case the park exists to
// bound, made N times worse and invisible to every single-waiter test.
func TestPullFIFOWakeReleasesEveryParkedRefuser(t *testing.T) {
	f := NewPullFIFO()
	defer f.Close()
	released := parkRefusers(t, f, 2)

	f.Wake() // exactly one control tick

	if !waitFor(func() bool { return atomic.LoadInt32(&f.parked) == 0 }, 2*time.Second) {
		t.Fatalf("one Wake left %d of 2 refusers still parked. With every link refusing, "+
			"the tick is the only release in the system, so a per-tick release of one "+
			"leaves N-1 links parked for another PingIval", atomic.LoadInt32(&f.parked))
	}
	awaitAll(t, released, "Wake")
}

// Wake -> cv, the Draw half. The claim is that Wake releases EVERY blocked
// drawer so it can re-evaluate its own liveness gate; under a Signal a drawer
// whose link has just gone dead can sit up to N ticks behind that gate.
func TestPullFIFOWakeReleasesEveryParkedDrawer(t *testing.T) {
	f := NewPullFIFO()
	defer f.Close()
	out := parkDrawers(t, f, 2)

	f.Wake() // exactly one control tick

	for i := 0; i < 2; i++ {
		select {
		case ok := <-out:
			if ok {
				t.Fatal("a drawer returned a frame from an empty pool")
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("one Wake released %d of 2 parked drawers. Wake is the liveness "+
				"re-evaluation point for every drawer; releasing one per tick puts the "+
				"other N-1 that many ticks behind their own gate", i)
		}
	}
}

// The INVERSE claim, and the same blind spot: content() is a plain Signal
// because exactly one frame became available, so exactly one drawer should be
// released. With one parked drawer that is indistinguishable from a Broadcast;
// with two, a Broadcast is a thundering herd -- N-1 drawers wake, find n == 0,
// and go straight back to cv.Wait, per arriving packet at the WG read rate.
func TestPullFIFOEnqueueReleasesExactlyOneParkedDrawer(t *testing.T) {
	f := NewPullFIFO()
	defer f.Close()
	out := parkDrawers(t, f, 2)

	f.Enqueue([]byte{7}, time.Now()) // exactly one frame becomes available

	select {
	case ok := <-out:
		if !ok {
			t.Fatal("the released drawer came back empty: one frame was enqueued and the " +
				"drawer that woke for it did not get it")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Enqueue released no drawer at all")
	}
	select {
	case <-out:
		t.Fatal("Enqueue released a SECOND drawer for a ONE-frame enqueue. content() is a " +
			"Signal precisely so that a pool mutation wakes one waiter; a Broadcast here " +
			"wakes every parked link once per arriving WG packet to find an empty pool")
	case <-time.After(50 * time.Millisecond):
	}
}

// Return is a ROLLBACK. It is evidence that a link could NOT place a frame --
// the opposite of evidence that a device is draining -- so it must not release a
// link parked on backpressure. This is the root cause of the N >= 2 spin: while
// Return was in the drain wake set, one refuser's rollback released another.
func TestPullFIFOReturnDoesNotReleaseParkedRefuser(t *testing.T) {
	f := NewPullFIFO()
	released := parkRefuser(t, f)

	f.Return(&PullFrame{seq: 0, enq: time.Now(), payload: []byte{1}}, time.Now())
	select {
	case <-released:
		t.Fatal("Return released a link parked on backpressure. A rollback says a link " +
			"could not send; it says nothing about a device draining. With it in the " +
			"drain wake set, two permanently refusing links wake each other forever.")
	case <-time.After(50 * time.Millisecond):
	}

	// And it is not merely STUCK: real drain evidence still releases it.
	f.Progress()
	select {
	case <-released:
	case <-time.After(2 * time.Second):
		t.Fatal("Progress did not release the parked refuser after the Return")
	}
}

// Enqueue is not drain evidence either. More work in the pool does not make a
// full device queue accept a write, and at the WG read rate it would wake every
// refuser once per arriving packet.
func TestPullFIFOEnqueueDoesNotReleaseParkedRefuser(t *testing.T) {
	f := NewPullFIFO()
	released := parkRefuser(t, f)

	f.Enqueue([]byte{1, 2, 3}, time.Now())
	select {
	case <-released:
		t.Fatal("Enqueue released a link parked on backpressure. A new frame in the " +
			"pool is not a reason to believe this link's socket will now accept one.")
	case <-time.After(50 * time.Millisecond):
	}

	f.Progress()
	select {
	case <-released:
	case <-time.After(2 * time.Second):
		t.Fatal("Progress did not release the parked refuser after the Enqueue")
	}
}

// The positive half of the same claim, with no control tick in play: a write
// that SUCCEEDED is the only direct evidence this daemon has that a device is
// draining, so it must release a parked refuser.
// This test parks ONE waiter, so it CANNOT distinguish Broadcast from Signal --
// the EVERY half of the claim is carried by
// TestPullFIFOProgressReleasesEveryParkedRefuser below, not by this test.
func TestPullFIFOProgressReleasesParkedRefuser(t *testing.T) {
	f := NewPullFIFO()
	released := parkRefuser(t, f)

	f.Progress()
	select {
	case <-released:
	case <-time.After(2 * time.Second):
		t.Fatal("Progress did not release the parked refuser -- a successful write is " +
			"the only datapath event in the drain wake set; without it the park is a " +
			"hang until the control tick")
	}
}

// A parked refuser must be released by a pool event. Wake is the worst-case one
// (the control tick), so it is the one asserted here: without it the park would
// be a hang rather than a bounded retry.
func TestPullDriveParkedRefuserIsReleasedByWake(t *testing.T) {
	f := NewPullFIFO()
	fs := newFakeSock(0, wrapErrno(syscall.ENOBUFS))
	l := newPullLinkSock(0, "if0", fs, testDst())
	f.Enqueue([]byte{1}, time.Now())

	done := make(chan struct{})
	go func() { l.Drive(f); close(done) }()

	if !waitFor(func() bool { return fs.tries() >= 1 }, 2*time.Second) {
		t.Fatal("link never attempted the first write")
	}
	first := fs.tries()
	stop := tickWake(f)
	ok := waitFor(func() bool { return fs.tries() > first }, 2*time.Second)
	stop()
	f.Close()
	<-done
	if !ok {
		t.Fatalf("Wake did not release the parked refuser: attempts stuck at %d", first)
	}
}

// REFUSING LINKS MUST NOT STARVE THE HEALTHY ONE, FOR ANY N. This is the
// property the whole design rests on -- share falls out of real drain -- and the
// previous version asserted it at N=2 only, with exactly one refuser. The rule
// here is N-generic, so the test is: N-1 links refuse every write forever, one
// takes everything, and every frame must leave exactly once on that one.
//
// There is deliberately NO tickWake. With one, the refusers' retries could be
// coming from the control tick and the test would say nothing about the datapath
// wake set; without one, the healthy link's Progress -- a write that SUCCEEDED
// -- is the only thing that can release them, so this also executes the positive
// half of the drain wake set end to end, at every N.
//
// The refusals are STAGED rather than raced for, and that is a second defect
// this round found in the test's own shape. Starting every link against a
// 200-frame burst makes "a refuser ever refuses anything" a scheduling accident:
// Enqueue Signals ONE waiter, and Go's mutex barges, so a zero-delay healthy
// link can drain the whole burst before a refuser is scheduled at all. The old
// version hid that behind tickWake, whose Broadcast periodically shook the
// refuser loose; with the tick removed it failed outright -- "the refusing link
// never recorded a refusal" -- proving that assertion had been decorative. So
// the refusers are driven against ONE frame first and the test WAITS until every
// one of them has recorded a refusal before the healthy link or the rest of the
// burst exist. (That chain works because a Return still Signals cv, so each
// refuser's rollback hands the staged frame to the next refuser waiting in Draw.
// It does NOT release the ones already parked on backpressure: that is the
// distinction this round exists to make.)
func TestPullDriveRefusingLinksDoNotStarveHealthyLinkForAnyN(t *testing.T) {
	for _, n := range []int{2, 3, 5} {
		const frames = 200
		f := NewPullFIFO()
		var wg sync.WaitGroup
		now := time.Now()

		bad := make([]*PullLink, n-1)
		for i := range bad {
			bad[i] = newPullLinkSock(i, "bad", newFakeSock(0, wrapErrno(syscall.ENOBUFS)), testDst())
		}
		good := newFakeSock(0, nil)
		healthy := newPullLinkSock(n-1, "good", good, testDst())

		f.Enqueue([]byte{0, 0}, now)
		for i := range bad {
			l := bad[i]
			wg.Add(1)
			go func() { defer wg.Done(); l.Drive(f) }()
		}
		staged := waitFor(func() bool {
			for _, l := range bad {
				if l.Bpress() == 0 {
					return false
				}
			}
			return true
		}, 5*time.Second)
		if !staged {
			f.Close()
			wg.Wait()
			t.Fatalf("N=%d: not every refuser drew the staged frame, so nothing below "+
				"would have been asserted about a full set of refusers", n)
		}

		wg.Add(1)
		go func() { defer wg.Done(); healthy.Drive(f) }()
		for i := 1; i < frames; i++ {
			f.Enqueue([]byte{byte(i), byte(i >> 8)}, now)
		}
		okAll := waitFor(func() bool { return healthy.Sent() == frames }, 10*time.Second)
		f.Close()
		wg.Wait()

		if !okAll {
			t.Fatalf("N=%d: healthy link sent %d of %d -- the %d refusing links starved it",
				n, healthy.Sent(), frames, n-1)
		}
		for i, l := range bad {
			if l.Sent() != 0 {
				t.Fatalf("N=%d: always-refusing link %d reports sent=%d, want 0", n, i, l.Sent())
			}
		}
		// Exactly-once, by seq, on the wire.
		seen := make(map[uint32]int)
		for _, fw := range good.frames() {
			_, pid, sq, _, _, _, err := Unpack(fw.b)
			if err != nil {
				t.Fatalf("N=%d: healthy link wrote a frame that does not unpack: %v", n, err)
			}
			if pid != byte(n-1) {
				t.Fatalf("N=%d: healthy link emitted pathID %d, want %d", n, pid, n-1)
			}
			seen[sq]++
		}
		if len(seen) != frames {
			t.Fatalf("N=%d: healthy link placed %d distinct seqs, want %d", n, len(seen), frames)
		}
		for sq, c := range seen {
			if c != 1 {
				t.Fatalf("N=%d: seq %d written %d times, want 1", n, sq, c)
			}
		}
		depth, _, enq, drawn, _ := f.Stats()
		if depth != 0 || enq != frames || drawn != frames {
			t.Fatalf("N=%d: depth=%d enq=%d drawn=%d, want 0/%d/%d", n, depth, enq, drawn, frames, frames)
		}
	}
}

// The operator override still works and is still charged to BlockedMs: setting a
// real sleep must not silently become the park.
func TestPullBackoffOperatorSleepIsChargedToBlocked(t *testing.T) {
	old := txBackoff
	txBackoff = 20 * time.Millisecond
	defer func() { txBackoff = old }()

	f := NewPullFIFO()
	l := newPullLinkSock(0, "if0", newFakeSock(0, nil), testDst())
	l.backoff(f)
	if got := l.BlockedMs(); got < 10 {
		t.Fatalf("BlockedMs=%dms after a %v operator backoff, want >= 10", got, txBackoff)
	}
}

// ---------------------------------------------------------------------------
// BLOCKER 2 -- the one-byte pathID ceiling, enforced rather than truncated.
// ---------------------------------------------------------------------------

// A link at or past the wire's pathID ceiling must never put a frame on the
// wire: byte(idx) would truncate mod 256 and two links would share a pathID, so
// the peer would merge their OWD, LossMeter and fseq series and report per-path
// loss fabricated from two interleaved sub-sequences.
func TestPullLinkPastWirePathIDCeilingNeverWrites(t *testing.T) {
	for _, idx := range []int{MaxLinks, MaxLinks + 1, 2 * MaxLinks} {
		fs := newFakeSock(0, nil)
		l := newPullLinkSock(idx, "over", fs, testDst())
		out := make([]byte, MaxPayload+HdrLen)
		fr := &PullFrame{seq: 1, enq: time.Now(), payload: []byte{1}}
		if r := l.send(fr, out); r != sendPathDown {
			t.Fatalf("idx=%d: send=%d, want sendPathDown", idx, r)
		}
		if fs.tries() != 0 {
			t.Fatalf("idx=%d: the socket saw %d writes; a truncated pathID reached the wire",
				idx, fs.tries())
		}
		if l.Errs() != 1 || l.Sent() != 0 || l.Bpress() != 0 {
			t.Fatalf("idx=%d: errs=%d sent=%d bpress=%d, want 1/0/0",
				idx, l.Errs(), l.Sent(), l.Bpress())
		}
	}
	// And the ceiling is the WIRE's, so the last addressable index still works.
	fs := newFakeSock(0, nil)
	l := newPullLinkSock(MaxLinks-1, "last", fs, testDst())
	out := make([]byte, MaxPayload+HdrLen)
	if r := l.send(&PullFrame{seq: 1, enq: time.Now(), payload: []byte{1}}, out); r != sendOK {
		t.Fatalf("idx=%d: send=%d, want sendOK -- %d is addressable", MaxLinks-1, r, MaxLinks-1)
	}
	w := fs.frames()
	if _, pid, _, _, _, _, err := Unpack(w[0].b); err != nil || int(pid) != MaxLinks-1 {
		t.Fatalf("pathID=%d err=%v, want %d", pid, err, MaxLinks-1)
	}
}

// Such a link must also not DRAW: it would pull frames out of the shared pool
// and destroy them. Drive exits immediately and leaves the pool untouched.
func TestPullDriveExcludesUnrunnableLinks(t *testing.T) {
	cases := []struct {
		name string
		l    *PullLink
	}{
		{"past the pathID ceiling", newPullLinkSock(MaxLinks, "over", newFakeSock(0, nil), testDst())},
		{"nil socket", NewPullLink(0, "nosock", nil, testDst())},
	}
	for _, c := range cases {
		f := NewPullFIFO()
		link := c.l
		f.Enqueue([]byte{1}, time.Now())
		done := make(chan struct{})
		go func() { link.Drive(f); close(done) }()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Fatalf("%s: Drive did not exit; it is drawing frames it can never send", c.name)
		}
		if depth, _, _, drawn, _ := f.Stats(); depth != 1 || drawn != 0 {
			t.Fatalf("%s: depth=%d drawn=%d, want 1/0 -- the pool must be untouched",
				c.name, depth, drawn)
		}
	}
}

// The nil-socket guard, directly: SndBuf already guarded it, send did not, and
// the N-genericity tests build links with nil conns. A nil *net.UDPConn must
// become a nil INTERFACE, not a typed-nil that compares non-nil.
func TestPullLinkNilSocketIsRefusedNotDereferenced(t *testing.T) {
	l := NewPullLink(0, "if0", nil, testDst())
	if l.sock != nil {
		t.Fatal("a nil *net.UDPConn was stored as a typed-nil interface")
	}
	if got := l.SndBuf(); got != -1 {
		t.Fatalf("SndBuf=%d on a socketless link, want -1", got)
	}
	out := make([]byte, MaxPayload+HdrLen)
	if r := l.send(&PullFrame{seq: 1, enq: time.Now(), payload: []byte{1}}, out); r != sendPathDown {
		t.Fatalf("send=%d on a socketless link, want sendPathDown", r)
	}
	if l.Errs() != 1 {
		t.Fatalf("errs=%d, want 1", l.Errs())
	}
}

// A fake socket has no fd, so SndBuf must report -1 rather than a plausible
// number. That is what keeps the derived byte bound honest in pullrun.go: an
// unreadable SO_SNDBUF is counted as unknown and logged, never guessed.
func TestPullLinkSndBufUnreadableReportsMinusOne(t *testing.T) {
	l := newPullLinkSock(0, "if0", newFakeSock(0, nil), testDst())
	if got := l.SndBuf(); got != -1 {
		t.Fatalf("SndBuf=%d with no readable fd, want -1", got)
	}
}

// ---------------------------------------------------------------------------
// S6 -- the pool is a ring deque. Return used to be an O(depth) memmove UNDER
// the pool mutex on the refusal hot path, with the mutex the WG reader's Enqueue
// and every other link's Draw need. The ring makes it O(1); these assert that it
// is still correct across a wrap, which is the case the memmove could not get
// wrong and a ring can.
// ---------------------------------------------------------------------------

func TestPullFIFORingSurvivesWrapAndReturnsAtHead(t *testing.T) {
	f := NewPullFIFO()
	now := time.Now()
	for i := 0; i < 10; i++ {
		f.Enqueue([]byte{byte(i)}, now)
	}
	// Draw 6, so the head index is well inside the ring.
	drawn := make([]*PullFrame, 0, 6)
	for i := 0; i < 6; i++ {
		fr, ok := f.Draw()
		if !ok || fr.Seq() != uint32(i) {
			t.Fatalf("draw %d: ok=%v", i, ok)
		}
		drawn = append(drawn, fr)
	}
	// Refill past the old capacity so the ring grows with a nonzero head.
	for i := 10; i < 20; i++ {
		f.Enqueue([]byte{byte(i)}, now)
	}
	// Roll back three, newest-refused first, exactly as three links refusing in
	// sequence would: the head must end up 3,4,5.
	for i := 5; i >= 3; i-- {
		f.Return(drawn[i], now)
	}
	// Draw parks on an empty OPEN pool, so close it before draining.
	f.Close()
	want := uint32(3)
	for {
		fr, ok := f.Draw()
		if !ok {
			break
		}
		if fr.Seq() != want {
			t.Fatalf("ring order broken: got seq %d, want %d", fr.Seq(), want)
		}
		want++
	}
	if want != 20 {
		t.Fatalf("drained up to seq %d, want 20", want)
	}
	if bytes, _, _, _, retq := f.ByteStats(); bytes != 0 || retq != 3 {
		t.Fatalf("bytes=%d retq=%d after full drain, want 0/3", bytes, retq)
	}
}

// The ring must keep byte accounting exact through an arbitrary interleaving of
// enqueue, draw and return -- the accounting the byte limb of the pool bound
// depends on.
func TestPullFIFORingByteAccountingIsExactUnderChurn(t *testing.T) {
	f := NewPullFIFO()
	now := time.Now()
	var held []*PullFrame
	live := 0
	for round := 0; round < 200; round++ {
		f.Enqueue(make([]byte, 1+round%97), now)
		live++
		if round%3 == 0 {
			if fr, ok := f.Draw(); ok {
				held = append(held, fr)
				live--
			}
		}
		if round%7 == 0 && len(held) > 0 {
			fr := held[len(held)-1]
			held = held[:len(held)-1]
			f.Return(fr, now)
			live++
		}
	}
	depth, _, _, _, _ := f.Stats()
	if depth != live {
		t.Fatalf("depth=%d, want %d", depth, live)
	}
	f.Close()
	want := 0
	for {
		fr, ok := f.Draw()
		if !ok {
			break
		}
		want += wireBytes(fr)
	}
	if bytes, _, _, _, _ := f.ByteStats(); bytes != 0 {
		t.Fatalf("byte occupancy %d after draining the pool, want 0 (drained %d bytes)", bytes, want)
	}
}
