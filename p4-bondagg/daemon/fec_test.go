package main

import (
	"bytes"
	"encoding/binary"
	"testing"
	"time"
)

// TestFecRoundtripPerPath: per-path FEC group over contiguous fseq, single loss
// (fseq 2). Rebuild must recover BOTH the missing payload AND its GLOBAL seq via
// the parity's seqXOR (gseq != fseq, so seq recovery is exercised distinctly).
func TestFecRoundtripPerPath(t *testing.T) {
	tx := &FecTx{}
	tx.SetK(4)
	gseqs := []uint32{5010, 5011, 5012, 5013}
	payloads := [][]byte{{1, 2, 3}, {4, 5}, {6, 7, 8, 9}, {10}}
	var parity []byte
	var pstart uint32
	var pk byte
	for i := range payloads {
		pp, ps, k := tx.Add(gseqs[i], uint32(i), payloads[i])
		if pp != nil {
			parity, pstart, pk = pp, ps, k
		}
	}
	if parity == nil {
		t.Fatal("no parity emitted")
	}
	if pstart != 0 || pk != 4 {
		t.Fatalf("parity start/k: got %d/%d want 0/4", pstart, pk)
	}
	rx := NewFecRx()
	rx.Parity(pstart, int(pk), parity)
	// deliver fseq 0,1,3 (fseq 2 lost) -- none may rebuild (loss unproven)
	for i := range payloads {
		if i == 2 {
			continue
		}
		if _, _, ok := rx.Data(uint32(i), gseqs[i], payloads[i]); ok {
			t.Fatalf("rebuild before loss proven at fseq %d", i)
		}
	}
	// stream continues (fseq 4): maxSeen-missing = 4-2 = 2 -> proof -> rebuild
	rs, rd, ok := rx.Data(4, 5014, []byte{99})
	if !ok || rs != gseqs[2] || !bytes.Equal(rd, payloads[2]) {
		t.Fatalf("rebuild wrong: ok=%v rs=%d rd=%v (want gseq %d %v)", ok, rs, rd, gseqs[2], payloads[2])
	}
}

func TestTiers(t *testing.T) {
	for _, c := range []struct {
		l float64
		k int
	}{{0.1, 0}, {1.0, 20}, {2.0, 12}, {5.0, 8}} {
		if tierK(c.l) != c.k {
			t.Fatalf("tier %v", c)
		}
	}
}

// TestTierKHyst: deadband hysteresis -- strengthen edges sit ABOVE nominal,
// weaken edges BELOW; inside the band HOLD.
func TestTierKHyst(t *testing.T) {
	cases := []struct {
		loss float64
		cur  int
		want int
	}{
		{0.50, 0, 0},   // below raise 0.55 -> hold off
		{0.60, 0, 20},  // above raise 0.55 -> strengthen to 20
		{1.00, 20, 20}, // inside 20's band -> hold
		{0.20, 20, 0},  // below lower 0.25 -> weaken candidate 0
		{1.00, 12, 20}, // below lower 1.25 -> weaken candidate 20
		{2.00, 12, 12}, // inside 12's band (lower 3.75, raise 2.75) -> hold
		{5.30, 12, 8},  // above raise 5.25 -> strengthen to 8
		{3.00, 8, 12},  // below lower 3.75 -> weaken candidate 12
		{3.50, 8, 12},  // below lower 3.75 -> weaken candidate 12
	}
	for _, c := range cases {
		if got := tierKHyst(c.loss, c.cur); got != c.want {
			t.Fatalf("tierKHyst(%.2f,%d)=%d want %d", c.loss, c.cur, got, c.want)
		}
	}
}

// TestParityAfterDataPerPath: parity arrives LAST (normal case). Retroactive
// membership + seqXOR recovery rebuilds the missing fseq's global seq.
func TestParityAfterDataPerPath(t *testing.T) {
	f := NewFecRx()
	pl := func(i int) []byte { return []byte{byte(i), 0xAA, byte(i * 3), 0x55} }
	gseq := func(i int) uint32 { return uint32(i) + 1000 }
	par := make([]byte, 6+4)
	var sx uint32
	var xl uint16
	for i := 0; i < 8; i++ {
		sx ^= gseq(i)
		xl ^= 4
		for j := 0; j < 4; j++ {
			par[6+j] ^= pl(i)[j]
		}
	}
	binary.BigEndian.PutUint32(par[0:4], sx)
	par[4], par[5] = byte(xl>>8), byte(xl)
	for i := 0; i < 7; i++ { // deliver fseq 0..6 (fseq 7 lost)
		if _, _, ok := f.Data(uint32(i), gseq(i), pl(i)); ok {
			t.Fatalf("premature rebuild at %d", i)
		}
	}
	if _, _, ok := f.Parity(0, 8, par); ok {
		t.Fatalf("rebuild before loss proven")
	}
	f.Data(8, gseq(8), pl(8)) // maxSeen=8: 8-7 < 2, still gated
	rs, rd, ok := f.Data(9, gseq(9), pl(9))
	if !ok || rs != gseq(7) {
		t.Fatalf("want rebuild gseq %d, got ok=%v rs=%d", gseq(7), ok, rs)
	}
	for j := 0; j < 4; j++ {
		if rd[j] != pl(7)[j] {
			t.Fatalf("payload byte %d: got %x want %x", j, rd[j], pl(7)[j])
		}
	}
}

// TestTierCtlStreak: strengthen instant; weaken only after a 4 consecutive
// weaker-candidate streak; an equal candidate resets the streak.
func TestTierCtlStreak(t *testing.T) {
	now := time.Unix(1000, 0)
	var applied [][2]int
	apply := func(o, n int) { applied = append(applied, [2]int{o, n}) }

	tc := &tierCtl{}
	tc.StepHyst(now, 6.0, apply) // raise(6.0)=8 -> strengthen instant
	if tc.K() != 8 || len(applied) != 1 || applied[0] != [2]int{0, 8} {
		t.Fatalf("tighten must be instant: k=%d applied=%v", tc.K(), applied)
	}
	// four weaker candidates (loss 0.0 -> weaken candidate below lower edge)
	for i := 0; i < 3; i++ {
		tc.StepHyst(now, 0.0, apply)
		if tc.K() != 8 {
			t.Fatalf("relax applied early at %d (k=%d)", i, tc.K())
		}
	}
	tc.StepHyst(now, 0.0, apply) // 4th -> one level weaker: 8 -> 12
	if tc.K() != 12 || applied[len(applied)-1] != [2]int{8, 12} {
		t.Fatalf("4th consecutive relax applies one level: k=%d applied=%v", tc.K(), applied)
	}
	// an equal/in-band candidate resets the streak
	tc2 := &tierCtl{}
	tc2.StepHyst(now, 6.0, apply) // -> 8
	tc2.StepHyst(now, 0.0, apply) // weaker 1
	tc2.StepHyst(now, 0.0, apply) // weaker 2
	tc2.StepHyst(now, 4.0, apply) // in 8's deadband (lower 3.75) -> HOLD, resets streak
	tc2.StepHyst(now, 0.0, apply) // weaker 1 again
	tc2.StepHyst(now, 0.0, apply) // weaker 2
	tc2.StepHyst(now, 0.0, apply) // weaker 3
	if tc2.K() != 8 {
		t.Fatalf("streak survived a reset: k=%d", tc2.K())
	}
}

// TestCollapseHold: during the hold, weakening is frozen and does not even
// accumulate the streak; strengthening stays instant; after release the 4-streak
// resumes. The K jump never weakens.
func TestCollapseHold(t *testing.T) {
	t0 := time.Unix(4000, 0)
	var applied [][2]int
	apply := func(o, n int) { applied = append(applied, [2]int{o, n}) }

	tc := &tierCtl{}
	tc.Collapse(t0, apply) // 0 -> 8 (strengthen), holdUntil = t0 + FecCollapseHold
	if tc.K() != 8 {
		t.Fatalf("collapse must jump to %d, got %d", FecCollapseK, tc.K())
	}
	for i := 0; i < 8; i++ { // weakening frozen for the whole window
		tc.StepHyst(t0.Add(1*time.Second), 0.0, apply)
		if tc.K() != 8 {
			t.Fatalf("weakening not frozen inside hold at %d (k=%d)", i, tc.K())
		}
	}
	// after release: a FRESH 4-streak is needed (the hold did not accumulate)
	tc.StepHyst(t0.Add(3*time.Second), 0.0, apply)
	tc.StepHyst(t0.Add(3*time.Second), 0.0, apply)
	tc.StepHyst(t0.Add(3*time.Second), 0.0, apply)
	if tc.K() != 8 {
		t.Fatalf("streak should still be gathering (3/4) after release, k=%d", tc.K())
	}
	tc.StepHyst(t0.Add(3*time.Second), 0.0, apply)
	if tc.K() != 12 {
		t.Fatalf("post-hold weakening must relax one level, k=%d", tc.K())
	}

	// strengthening (and the no-weaken guard) inside a hold: from K20, high loss
	// strengthens to 8 instantly; Collapse from a stronger tier never weakens.
	tc2 := &tierCtl{k: 20, holdUntil: t0.Add(5 * time.Second)}
	tc2.StepHyst(t0.Add(1*time.Second), 6.0, apply)
	if tc2.K() != 8 {
		t.Fatalf("strengthening must be instant inside hold, k=%d", tc2.K())
	}
	tc3 := &tierCtl{k: 8}
	tc3.Collapse(t0, apply) // already strongest: no weaken, no change
	if tc3.K() != 8 {
		t.Fatalf("collapse must not weaken K already at %d, got %d", FecCollapseK, tc3.K())
	}
}

// TestPhantomRebuildGate: early parity + last member merely in flight -> NO
// rebuild until the stream provably continues past the hole.
func TestPhantomRebuildGate(t *testing.T) {
	f := NewFecRx()
	pl := func(i int) []byte { return []byte{byte(i), 1, 2, 3} }
	gseq := func(i int) uint32 { return uint32(i) + 7000 }
	par := make([]byte, 6+4)
	var sx uint32
	var xl uint16
	for i := 0; i < 8; i++ {
		sx ^= gseq(i)
		xl ^= 4
		for j := 0; j < 4; j++ {
			par[6+j] ^= pl(i)[j]
		}
	}
	binary.BigEndian.PutUint32(par[0:4], sx)
	par[4], par[5] = byte(xl>>8), byte(xl)
	for i := 0; i < 7; i++ {
		f.Data(uint32(i), gseq(i), pl(i))
	}
	if _, _, ok := f.Parity(0, 8, par); ok {
		t.Fatalf("phantom rebuild: fseq 7 not proven lost")
	}
	if _, _, ok := f.Data(8, gseq(8), pl(8)); ok {
		t.Fatalf("maxSeen=8: still no proof (need missing+2)")
	}
	rs, rd, ok := f.Data(9, gseq(9), pl(9))
	if !ok || rs != gseq(7) {
		t.Fatalf("proof arrived, want rebuild gseq %d: ok=%v rs=%d", gseq(7), ok, rs)
	}
	for j := 0; j < 4; j++ {
		if rd[j] != pl(7)[j] {
			t.Fatalf("payload mismatch at %d", j)
		}
	}
}

// addGroup registers an RX group white-box with a controlled born and haveN
// present members (so k-haveN count as missing/lost at retirement).
func addGroup(f *FecRx, start uint32, k, haveN int, born time.Time) {
	g := &fgroup{start: start, k: k, born: born, have: map[uint32]recEntry{}}
	for i := 0; i < haveN; i++ {
		g.have[start+uint32(i)] = recEntry{gseq: start + uint32(i), data: []byte{0}}
	}
	f.groups[start] = g
	f.order = append(f.order, start)
}

// TestAgeRetire (P1): a group older than FecRetireAge is retired by the age sweep
// and its missing members counted; a fresh group is kept; the 64-displacement
// backstop still fires independently of age.
func TestAgeRetire(t *testing.T) {
	t0 := time.Unix(2000, 0)
	f := NewFecRx()
	addGroup(f, 0, 8, 6, t0)                             // 2 missing
	addGroup(f, 100, 8, 8, t0.Add(400*time.Millisecond)) // 0 missing

	f.gc(t0)
	if _, ok := f.groups[0]; !ok {
		t.Fatalf("group retired too early at t0")
	}
	if f.rawLost != 0 || f.rawSeen != 0 {
		t.Fatalf("no retirement expected at t0: lost=%d seen=%d", f.rawLost, f.rawSeen)
	}

	f.gc(t0.Add(700 * time.Millisecond)) // stale (700>600) retires; fresh (300) stays
	if _, ok := f.groups[0]; ok {
		t.Fatalf("stale group not retired by age")
	}
	if _, ok := f.groups[100]; !ok {
		t.Fatalf("fresh group wrongly retired by age")
	}
	if f.rawLost != 2 || f.rawSeen != 8 {
		t.Fatalf("age-retire accounting: lost=%d seen=%d want 2/8", f.rawLost, f.rawSeen)
	}

	f2 := NewFecRx()
	base := time.Unix(3000, 0)
	for i := 0; i < 100; i++ {
		addGroup(f2, uint32(i)*10, 4, 1, base)
	}
	f2.gc(base) // now==born: only the 64-displacement backstop fires
	if len(f2.order) != 64 {
		t.Fatalf("64-backstop: order=%d want 64", len(f2.order))
	}
	if f2.rawLost != 36*3 || f2.rawSeen != 36*4 {
		t.Fatalf("backstop accounting: lost=%d seen=%d want %d/%d", f2.rawLost, f2.rawSeen, 36*3, 36*4)
	}
}

// TestLossMeter: reorder-tolerant per-path fseq-gap loss with ring-skip (TIME-
// based) semantics. A frame that arrives LATE but within `hold` fills its gap
// and is NOT loss; a frontier gap that stays open longer than `hold` is loss.
func TestLossMeter(t *testing.T) {
	t0 := time.Unix(3000, 0)
	hold := 100 * time.Millisecond
	if l, tot := (&LossMeter{}).Window(t0, hold); l != 0 || tot != 0 {
		t.Fatalf("empty meter should read 0/0, got %d/%d", l, tot)
	}
	// Case A: pure reorder INSIDE hold -> ZERO lost (the fix). fseq 5 arrives
	// after 6,7 but only ~2ms later, well within hold; must not count as loss.
	mA := &LossMeter{}
	for k, fs := range []uint32{0, 1, 2, 3, 4, 6, 7, 5, 8, 9, 10, 11, 12} {
		mA.Data(fs, t0.Add(time.Duration(k)*time.Millisecond), hold)
	}
	if lost, total := mA.Window(t0.Add(20*time.Millisecond), hold); lost != 0 || total == 0 {
		t.Fatalf("reorder within hold must not count as loss: lost=%d total=%d", lost, total)
	}
	// Case B: exactly one genuine loss. fseq 100 never arrives; the frontier gap
	// stays open longer than hold (later arrival is > hold after it blocked), so
	// it -- and only it -- is declared lost.
	mB := &LossMeter{}
	for i := uint32(60); i <= 99; i++ {
		mB.Data(i, t0, hold)
	}
	mB.Data(101, t0, hold)                               // gap 100 opens at t0
	mB.Data(102, t0.Add(hold+10*time.Millisecond), hold) // > hold later -> 100 lost
	if lost, total := mB.Window(t0.Add(2*hold), hold); lost != 1 || total < 2 {
		t.Fatalf("genuine loss miscounted: lost=%d total=%d (want lost=1)", lost, total)
	}
}
