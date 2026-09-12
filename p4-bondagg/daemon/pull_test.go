package main

import (
	"net"
	"sync"
	"testing"
	"time"
)

// The pull core's contract, in the order reserved_composite.py establishes it.

// seq is stamped AT ENQUEUE in app order (SimD.run's offer block), so the
// resequencer space is app order regardless of which link later carries a frame.
func TestPullFIFOSeqStampedAtEnqueueInAppOrder(t *testing.T) {
	f := NewPullFIFO()
	now := time.Now()
	for i := 0; i < 8; i++ {
		if got := f.Enqueue([]byte{byte(i)}, now); got != uint32(i) {
			t.Fatalf("enqueue %d: seq=%d want %d", i, got, i)
		}
	}
}

// The pool is a FIFO: the head frame is the unit of the draw.
func TestPullFIFODrawIsFIFOOrder(t *testing.T) {
	f := NewPullFIFO()
	now := time.Now()
	for i := 0; i < 8; i++ {
		f.Enqueue([]byte{byte(i)}, now)
	}
	for i := 0; i < 8; i++ {
		fr, ok := f.Draw()
		if !ok {
			t.Fatalf("draw %d: pool reported empty", i)
		}
		if fr.Seq() != uint32(i) {
			t.Fatalf("draw %d: seq=%d want %d", i, fr.Seq(), i)
		}
		if fr.payload[0] != byte(i) {
			t.Fatalf("draw %d: payload=%d want %d", i, fr.payload[0], i)
		}
	}
}

// Enqueue must OWN its copy: the WG read buffer is reused the instant it returns.
func TestPullFIFOEnqueueOwnsPayload(t *testing.T) {
	f := NewPullFIFO()
	buf := []byte{1, 2, 3}
	f.Enqueue(buf, time.Now())
	buf[0], buf[1], buf[2] = 9, 9, 9
	fr, ok := f.Draw()
	if !ok {
		t.Fatal("draw: pool reported empty")
	}
	if fr.payload[0] != 1 || fr.payload[1] != 2 || fr.payload[2] != 3 {
		t.Fatalf("payload aliased the caller's buffer: %v", fr.payload)
	}
}

// Trim is the oracle's pool bound (maxq_kb): OLDEST-first head-drop, and it must
// not touch anything inside the horizon.
func TestPullFIFOTrimHeadDropsOldestOnly(t *testing.T) {
	f := NewPullFIFO()
	now := time.Now()
	f.Enqueue([]byte{0}, now.Add(-400*time.Millisecond))
	f.Enqueue([]byte{1}, now.Add(-300*time.Millisecond))
	f.Enqueue([]byte{2}, now.Add(-10*time.Millisecond))
	if n := f.Trim(now, 200*time.Millisecond); n != 2 {
		t.Fatalf("trim dropped %d, want 2", n)
	}
	depth, _, _, _, stale := f.Stats()
	if depth != 1 || stale != 2 {
		t.Fatalf("depth=%d stale=%d, want 1/2", depth, stale)
	}
	fr, ok := f.Draw()
	if !ok || fr.Seq() != 2 {
		t.Fatalf("survivor seq=%v ok=%v, want seq 2", fr, ok)
	}
}

// Wake must release a parked drawer so it can re-check its own gates (liveness)
// without a frame being enqueued.
func TestPullFIFOWakeReleasesParkedDrawer(t *testing.T) {
	f := NewPullFIFO()
	done := make(chan bool, 1)
	go func() {
		_, ok := f.Draw()
		done <- ok
	}()
	// Level-triggered, exactly like the control loop: keep calling Wake until the
	// drawer reports back. A one-shot Wake would race the goroutine reaching Wait.
	tick := time.NewTicker(10 * time.Millisecond)
	defer tick.Stop()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case ok := <-done:
			if ok {
				t.Fatal("drawer returned a frame from an empty pool")
			}
			return
		case <-tick.C:
			f.Wake()
		case <-deadline:
			t.Fatal("Wake did not release the parked drawer")
		}
	}
}

// THE core property, and the one that must hold for every N: the pool is shared,
// so each frame is drawn by EXACTLY ONE link -- never duplicated, never lost.
// N here is just the number of drawers; nothing in the core is keyed to it.
func TestPullFIFOEachFrameDrawnExactlyOnceForAnyN(t *testing.T) {
	for _, n := range []int{1, 2, 3, 5, 8} {
		f := NewPullFIFO()
		const frames = 500
		now := time.Now()
		for i := 0; i < frames; i++ {
			f.Enqueue([]byte{byte(i)}, now)
		}
		var mu sync.Mutex
		got := make(map[uint32]int)
		var wg sync.WaitGroup
		for d := 0; d < n; d++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				for {
					fr, ok := f.Draw()
					if !ok {
						if f.Closed() {
							return
						}
						continue
					}
					mu.Lock()
					got[fr.Seq()]++
					mu.Unlock()
				}
			}()
		}
		// Drain, then release the drawers parked on the now-empty pool.
		deadline := time.Now().Add(5 * time.Second)
		for {
			mu.Lock()
			have := len(got)
			mu.Unlock()
			if have == frames || time.Now().After(deadline) {
				break
			}
			time.Sleep(time.Millisecond)
		}
		f.Close()
		wg.Wait()
		if len(got) != frames {
			t.Fatalf("N=%d: drew %d distinct frames, want %d", n, len(got), frames)
		}
		for seq, c := range got {
			if c != 1 {
				t.Fatalf("N=%d: seq %d drawn %d times, want 1", n, seq, c)
			}
		}
		_, _, enq, drawn, _ := f.Stats()
		if enq != frames || drawn != frames {
			t.Fatalf("N=%d: enq=%d drawn=%d, want %d/%d", n, enq, drawn, frames, frames)
		}
	}
}

// A closed pool releases every drawer, so no goroutine is stranded.
func TestPullFIFOCloseReleasesDrawers(t *testing.T) {
	f := NewPullFIFO()
	done := make(chan struct{})
	go func() {
		f.Draw()
		close(done)
	}()
	time.Sleep(20 * time.Millisecond)
	f.Close()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("Close did not release the parked drawer")
	}
	if !f.Closed() {
		t.Fatal("Closed() false after Close()")
	}
	if _, ok := f.Draw(); ok {
		t.Fatal("Draw returned a frame from a closed empty pool")
	}
}

// N-genericity of the core's construction: N is len(Links) and no index is
// special. Sockets are not touched here -- construction must not dereference them.
func TestPullCoreIsNGeneric(t *testing.T) {
	dst := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 1}
	for _, n := range []int{1, 2, 3, 4, 7} {
		devs := make([]string, n)
		conns := make([]*net.UDPConn, n)
		for i := range devs {
			devs[i] = "if" + string(rune('a'+i))
		}
		c := NewPullCore(devs, conns, dst)
		if c.N() != n {
			t.Fatalf("N()=%d want %d", c.N(), n)
		}
		for i, l := range c.Links {
			if l.Idx() != i {
				t.Fatalf("link %d reports idx %d", i, l.Idx())
			}
			if l.Ifname() != devs[i] {
				t.Fatalf("link %d ifname=%q want %q", i, l.Ifname(), devs[i])
			}
			if !l.Alive() {
				t.Fatalf("link %d not alive at construction", i)
			}
		}
	}
}

// A link that has not been heard from must stop drawing rather than write into a
// black hole; the liveness gate is level-triggered off RxAge.
func TestPullLinkLivenessGateIsLevelTriggered(t *testing.T) {
	l := NewPullLink(0, "if0", nil, nil)
	now := time.Now()
	if l.RxAge(now) > DeadIval {
		t.Fatalf("fresh link already stale: age=%v", l.RxAge(now))
	}
	l.SetAlive(l.RxAge(now) <= DeadIval)
	if !l.Alive() {
		t.Fatal("fresh link gated dead")
	}
	future := now.Add(10 * DeadIval)
	l.SetAlive(l.RxAge(future) <= DeadIval)
	if l.Alive() {
		t.Fatal("silent link still gated alive")
	}
	l.MarkRx()
	l.SetAlive(l.RxAge(time.Now()) <= DeadIval)
	if !l.Alive() {
		t.Fatal("link did not revive after MarkRx")
	}
}
