package main

import (
	"encoding/binary"
	"sync"
	"time"
)

// XOR-parity FEC, adaptive K, PER-PATH (P5). Parity frame: FlagFEC, seq32 =
// group fseq START, rsvd byte = K, payload = [seqXOR 4B][xlenXOR 2B][xorData
// padded to group max]. seqXOR lets the RX recover the missing frame's GLOBAL
// seq (needed for the resequencer ring) since per-path group members are not
// consecutive global seqs.
const FlagFEC = 0x3

// S3 peerloss fix (docs/knowledge/design/s3-peerloss-fix.md).
// P1 FecRetireAge: age horizon for RX group retirement (> HoldMax 350ms + path
// spread/jitter). P2 FecCollapseK / FecCollapseHold: on a control-plane collapse,
// jump K to FecCollapseK (strongest tier) and freeze weakening for FecCollapseHold.
const (
	FecRetireAge    = 600 * time.Millisecond
	FecCollapseK    = 8
	FecCollapseHold = 2500 * time.Millisecond
)

// tierK: nominal loss->tier map (SHARP boundaries). Kept for reference/tests;
// the live controller uses the hysteretic tierKHyst.
func tierK(lossPct float64) int {
	switch {
	case lossPct < 0.4:
		return 0
	case lossPct < 2.0:
		return 20
	case lossPct < 4.5:
		return 12
	default:
		return 8
	}
}

// N10 deadband hysteresis (fec-port-findings.md): raise edges sit a deadband
// ABOVE the nominal boundary (strengthen), lower edges a deadband BELOW
// (weaken). The band (>> report-to-report loss jitter) clears the congestion-
// spike ceiling so the tier tracks BASE loss and ignores transient spikes.
// Effective grid after 0.5% byte-quantize: raise 1.0/3.0/5.5, weaken 0.0/≤1.0/≤3.5.
func tierKRaise(lossPct float64) int { // STRENGTHEN candidate (raised edges)
	switch {
	case lossPct < 0.55:
		return 0
	case lossPct < 2.75:
		return 20
	case lossPct < 5.25:
		return 12
	default:
		return 8
	}
}
func tierKLower(lossPct float64) int { // WEAKEN candidate (lowered edges)
	switch {
	case lossPct < 0.25:
		return 0
	case lossPct < 1.25:
		return 20
	case lossPct < 3.75:
		return 12
	default:
		return 8
	}
}

// tierKHyst: strengthen on the RAISE map (still instant); propose a weaker tier
// only once loss falls below the LOWER map; inside the deadband HOLD cur. Feeds
// the unchanged tierCtl streak/hold logic -- only the CANDIDATE is hysteretic.
func tierKHyst(lossPct float64, cur int) int {
	up := tierKRaise(lossPct)
	if kStrength(up) > kStrength(cur) {
		return up
	}
	dn := tierKLower(lossPct)
	if kStrength(dn) < kStrength(cur) {
		return dn
	}
	return cur
}

// ---- TX group builder (per path) ----
type FecTx struct {
	mu    sync.Mutex
	K     int
	start uint32 // fstart (fseq) of the open group
	n     int
	xlen  uint16
	sxor  uint32 // XOR of member GLOBAL seqs (missing-seq recovery)
	xdata [MaxPayload]byte
	xmax  int
}

// Add folds one DATA frame (global gseq, per-path fseq, payload) into the open
// group. Returns a parity blob (+ its fstart + K) when the group completes.
func (f *FecTx) Add(gseq, fseq uint32, payload []byte) (parity []byte, pseq uint32, k byte) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.K == 0 {
		f.n = 0
		return nil, 0, 0
	}
	if f.n == 0 {
		f.start = fseq
		f.xlen = 0
		f.sxor = 0
		f.xmax = 0
		for i := range f.xdata {
			f.xdata[i] = 0
		}
	}
	f.xlen ^= uint16(len(payload))
	f.sxor ^= gseq
	for i, b := range payload {
		f.xdata[i] ^= b
	}
	if len(payload) > f.xmax {
		f.xmax = len(payload)
	}
	f.n++
	if f.n < f.K {
		return nil, 0, 0
	}
	out := make([]byte, 6+f.xmax)
	binary.BigEndian.PutUint32(out[0:4], f.sxor)
	out[4] = byte(f.xlen >> 8)
	out[5] = byte(f.xlen)
	copy(out[6:], f.xdata[:f.xmax])
	f.n = 0
	return out, f.start, byte(f.K)
}

func (f *FecTx) SetK(k int) {
	f.mu.Lock()
	if k != f.K {
		f.K = k
		f.n = 0 // abort open group: a mid-group K change would emit parity whose
		// claimed membership [start,start+K) mismatches the XORed set.
	}
	f.mu.Unlock()
}

func kStrength(k int) int {
	switch k {
	case 0:
		return 0
	case 20:
		return 1
	case 12:
		return 2
	default:
		return 3
	}
}

func oneWeaker(k int) int {
	switch k {
	case 8:
		return 12
	case 12:
		return 20
	default:
		return 0
	}
}

// tierCtl: FEC tier hysteresis, per path. OWNS K (TOCTOU fix: the Step decision
// and its SetK application are atomic under mu, so a concurrent Collapse can't be
// overwritten by a stale weaken). Strength order 0 < 20 < 12 < 8. Tightening is
// instant; relaxing steps ONE level weaker after 4 consecutive weaker candidates
// and only when no collapse hold is active.
type tierCtl struct {
	mu        sync.Mutex
	k         int
	cnt       int
	holdUntil time.Time // weakening frozen until this instant (collapse hold)
}

func (t *tierCtl) K() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.k
}

// StepHyst applies the hysteretic loss->tier decision. On a change it invokes
// apply(oldK, newK) while STILL holding t.mu (so the ftx.SetK + CapEst
// feedforward land atomically with the tier decision). apply must lock only
// ftx/CapEst, never tierCtl or Sched.
func (t *tierCtl) StepHyst(now time.Time, lossPct float64, apply func(oldK, newK int)) {
	t.mu.Lock()
	defer t.mu.Unlock()
	cur := t.k
	nk := tierKHyst(lossPct, cur)
	if kStrength(nk) > kStrength(cur) {
		t.cnt = 0
		t.k = nk
		apply(cur, nk) // strengthening is always instant, even inside a hold
		return
	}
	if nk == cur {
		t.cnt = 0
		return
	}
	if now.Before(t.holdUntil) {
		return // weakening frozen during a collapse hold
	}
	t.cnt++
	if t.cnt >= 4 {
		t.cnt = 0
		nw := oneWeaker(cur)
		t.k = nw
		apply(cur, nw)
	}
}

// Collapse: control-plane capacity collapse -> jump K to the strongest tier
// (never weaken) and freeze weakening for FecCollapseHold; reset the relax
// streak. The K jump + feedforward happen via apply, atomically under mu.
func (t *tierCtl) Collapse(now time.Time, apply func(oldK, newK int)) {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.holdUntil = now.Add(FecCollapseHold)
	t.cnt = 0
	if kStrength(FecCollapseK) > kStrength(t.k) {
		old := t.k
		t.k = FecCollapseK
		apply(old, FecCollapseK)
	}
}

// ---- RX group cache (per path, keyed by fseq) ----
type recEntry struct {
	gseq uint32
	data []byte
}

type fgroup struct {
	start   uint32 // fstart (fseq)
	k       int
	born    time.Time
	have    map[uint32]recEntry // keyed by fseq
	parity  []byte
	rebuilt bool
}

type FecRx struct {
	mu      sync.Mutex
	groups  map[uint32]*fgroup  // key = fstart (fseq)
	order   []uint32            // fstart order (born-monotonic)
	recent  map[uint32]recEntry // data seen recently, keyed by fseq
	rorder  []uint32
	maxSeen uint32 // newest fseq observed (loss proof)
	hasMax  bool
	rawLost uint64 // retire-time pre-FEC loss accounting (gc)
	rawSeen uint64
}

func NewFecRx() *FecRx {
	return &FecRx{groups: map[uint32]*fgroup{}, recent: map[uint32]recEntry{}}
}

const fecRecentCap = 2048

func (f *FecRx) remember(fseq, gseq uint32, payload []byte) recEntry {
	cp := make([]byte, len(payload))
	copy(cp, payload)
	re := recEntry{gseq: gseq, data: cp}
	if _, dup := f.recent[fseq]; !dup {
		f.rorder = append(f.rorder, fseq)
	}
	f.recent[fseq] = re
	for len(f.rorder) > fecRecentCap {
		delete(f.recent, f.rorder[0])
		f.rorder = f.rorder[1:]
	}
	return re
}

func inGroup(fseq uint32, g *fgroup) bool {
	return int32(fseq-g.start) >= 0 && int32(fseq-(g.start+uint32(g.k))) < 0
}

// gc runs under f.mu. Two retirement rules feed the SAME pre-FEC accounting:
// the 64-group displacement backstop, and age-based retirement (P1).
func (f *FecRx) gc(now time.Time) {
	for len(f.order) > 64 {
		st := f.order[0]
		if g := f.groups[st]; g != nil && g.k > 0 {
			if l := g.k - len(g.have); l > 0 {
				f.rawLost += uint64(l)
			}
			f.rawSeen += uint64(g.k)
		}
		delete(f.groups, st)
		f.order = f.order[1:]
	}
	for len(f.order) > 0 {
		st := f.order[0]
		g := f.groups[st]
		if g == nil {
			f.order = f.order[1:]
			continue
		}
		if now.Sub(g.born) <= FecRetireAge {
			break // born-monotonic order: every newer group is younger still
		}
		if g.k > 0 && (g.parity != nil || len(g.have) > 0) {
			if l := g.k - len(g.have); l > 0 {
				f.rawLost += uint64(l)
			}
			f.rawSeen += uint64(g.k)
		}
		delete(f.groups, st)
		f.order = f.order[1:]
	}
}

// TakeRaw sweeps age-retired groups into the counters and drains them.
func (f *FecRx) TakeRaw(now time.Time) (lost, seen uint64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.gc(now)
	lost, seen = f.rawLost, f.rawSeen
	f.rawLost, f.rawSeen = 0, 0
	return
}

func (f *FecRx) group(start uint32, k int, now time.Time) *fgroup {
	g, ok := f.groups[start]
	if !ok {
		g = &fgroup{start: start, k: k, born: now, have: map[uint32]recEntry{}}
		f.groups[start] = g
		f.order = append(f.order, start)
		f.gc(now)
	}
	if k > 0 {
		g.k = k
	}
	return g
}

// Data registers a received DATA frame (fseq, gseq); if a group with parity now
// misses exactly one member, rebuild it. Returns the recovered GLOBAL seq.
func (f *FecRx) Data(fseq, gseq uint32, payload []byte) (rseq uint32, rdata []byte, ok bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.hasMax || int32(fseq-f.maxSeen) > 0 {
		f.maxSeen, f.hasMax = fseq, true
	}
	re := f.remember(fseq, gseq, payload)
	for _, g := range f.groups {
		if inGroup(fseq, g) {
			g.have[fseq] = re
			if rs, rd, ok2 := f.try(g); ok2 {
				return rs, rd, true
			}
			break
		}
	}
	return f.sweepTry()
}

// sweepTry: groups whose rebuild was evidence-gated earlier get another chance
// as maxSeen advances. Bounded by gc at 64 groups.
func (f *FecRx) sweepTry() (uint32, []byte, bool) {
	for _, st := range f.order {
		g := f.groups[st]
		if g == nil || g.parity == nil || g.rebuilt {
			continue
		}
		if rs, rd, ok := f.try(g); ok {
			return rs, rd, true
		}
	}
	return 0, nil, false
}

func (f *FecRx) Parity(start uint32, k int, payload []byte) (rseq uint32, rdata []byte, ok bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	g := f.group(start, k, time.Now())
	cp := make([]byte, len(payload))
	copy(cp, payload)
	g.parity = cp
	for s := start; int32(s-(start+uint32(k))) < 0; s++ { // retroactive membership
		if re, ok2 := f.recent[s]; ok2 {
			g.have[s] = re
		}
	}
	return f.try(g)
}

func (f *FecRx) try(g *fgroup) (uint32, []byte, bool) {
	if g.parity == nil || g.rebuilt || g.k == 0 || len(g.have) != g.k-1 {
		return 0, nil, false
	}
	var missing uint32
	found := false
	for s := g.start; int32(s-(g.start+uint32(g.k))) < 0; s++ {
		if _, ok := g.have[s]; !ok {
			missing = s
			found = true
			break
		}
	}
	if !found {
		return 0, nil, false
	}
	// Evidence gate: rebuild only when >=2 newer fseqs have been seen (early
	// parity racing a slower path would otherwise rebuild in-flight frames).
	if !f.hasMax || int32(f.maxSeen-missing) < 2 {
		return 0, nil, false
	}
	if len(g.parity) < 6 {
		return 0, nil, false // malformed: too short for seqXOR+xlen header
	}
	recovGseq := binary.BigEndian.Uint32(g.parity[0:4])
	xlen := uint16(g.parity[4])<<8 | uint16(g.parity[5])
	max := len(g.parity) - 6
	buf := make([]byte, max)
	copy(buf, g.parity[6:])
	for _, re := range g.have {
		xlen ^= uint16(len(re.data))
		recovGseq ^= re.gseq
		for i, b := range re.data {
			if i >= max {
				break // malformed peer data must not panic us
			}
			buf[i] ^= b
		}
	}
	if int(xlen) > max {
		return 0, nil, false
	}
	g.rebuilt = true
	return recovGseq, buf[:xlen], true
}

// ---- per-path loss meter (reorder-tolerant, ring-skip semantics) ----------
// Per-path pre-FEC frame-loss %, from GENUINE gaps in the contiguous per-path
// fseq stream. Used ONLY at K=0 (bootstrap FEC / no parity): once FEC is armed
// the echo comes from the reorder-immune FEC-group ledger (frx.TakeRaw), so
// this is the exact daemon analogue of nsched_model.py _fec_report's K=0 branch
// wSkip/(wDel+wSkip) -- the RING's skip accounting (ring.go).
//
// Congestion taildrops DO count as loss (the tier DEADBAND + AIMD-in-series
// absorb that); but REORDER does NOT. A frame that merely arrives LATE (path
// jitter, or a collapsing path draining its queue) is out of order, not lost:
// it fills its gap and is counted DELIVERED. A frontier gap is declared LOST
// only once it has blocked for longer than `hold` -- the ring's owd-adaptive
// reorder horizon (paths.go owd.Hold). This is TIME-based, mirroring ring.go's
// O(1) blockN/blockAt gap timer, and is the fix for the earlier frame-COUNT
// grace: a fixed frame grace scales its detection lag INVERSELY with per-path
// pps, so EIF's lightly-loaded path armed FEC far too late (the S6 regression);
// a time horizon does not, matching the ledger's time-based 600ms retire.
//
// (History: the original meter differenced maxF over a fixed 500ms window and
// counted every still-in-flight reordered frame as loss, with a lost<0 clamp
// that blocked the next window's late arrival from refunding it -> a persistent
// positive loss bias under jitter/collapse-drain reorder that spuriously armed
// and corrupted the peerloss echo. This held-gap timer removes that.)
type LossMeter struct {
	mu       sync.Mutex
	next     uint32 // lowest fseq not yet resolved (delivered or lost)
	haveNext bool
	maxF     uint32 // highest fseq observed on this path
	haveMax  bool
	seen     map[uint32]struct{} // arrived fseqs >= next awaiting contiguity
	blockOn  bool                // a frontier gap is currently being timed
	blockN   uint32              // the fseq of that gap
	blockAt  time.Time           // when it was first observed
	deliv    int                 // frames resolved-delivered this window
	lost     int                 // frames declared genuinely-lost this window
}

// Data registers a received per-path DATA fseq at time `now`; `hold` is the
// current owd-adaptive reorder horizon (the same value fed to ring.Hold).
// Out-of-order frames fill their gap and count delivered; a frontier gap is
// counted lost only after it has blocked > hold.
func (m *LossMeter) Data(fseq uint32, now time.Time, hold time.Duration) {
	m.mu.Lock()
	if !m.haveNext {
		m.next, m.haveNext = fseq, true
	}
	if !m.haveMax || int32(fseq-m.maxF) > 0 {
		m.maxF, m.haveMax = fseq, true
	}
	if int32(fseq-m.next) < 0 {
		m.mu.Unlock()
		return // already resolved (late dup / already-skipped): ignore
	}
	if m.seen == nil {
		m.seen = make(map[uint32]struct{})
	}
	m.seen[fseq] = struct{}{}
	m.drain(now, hold)
	m.mu.Unlock()
}

// drain (m.mu held) advances the contiguous frontier: it delivers buffered
// fseqs in order, and skips a frontier gap -- only when there is newer evidence
// (maxF past it) AND it has blocked longer than hold -- batching the whole
// overdue run up to the next buffered arrival (ring.go overdue-epoch parity).
func (m *LossMeter) drain(now time.Time, hold time.Duration) {
	for m.haveNext {
		if _, ok := m.seen[m.next]; ok {
			delete(m.seen, m.next)
			m.deliv++
			m.next++
			m.blockOn = false
			continue
		}
		if !m.haveMax || int32(m.maxF-m.next) <= 0 {
			return // no newer evidence yet: next is not proven behind
		}
		if !m.blockOn || m.blockN != m.next {
			m.blockOn, m.blockN, m.blockAt = true, m.next, now
			return
		}
		if now.Sub(m.blockAt) <= hold {
			return // still inside the reorder horizon: wait for a late arrival
		}
		// overdue: skip the run of genuinely-missing fseqs up to the next
		// buffered arrival (maxF is always buffered, so this terminates).
		for int32(m.maxF-m.next) > 0 {
			if _, ok := m.seen[m.next]; ok {
				break
			}
			m.lost++
			m.next++
		}
		m.blockOn = false
	}
}

// Window (loss epoch, at time `now` with horizon `hold`) drains overdue gaps
// and returns the window's genuine-loss count and resolved-total (delivered +
// genuinely-lost), then resets them. The caller folds lost/total into the
// SINGLE per-path loss EWMA (main.go sLossE) -- the K=0 branch of
// nsched_model.py _fec_report, the exact analogue of the ring-skip fallback
// wSkip/(wDel+wSkip). Deliberately no internal EWMA: when FEC is armed the echo
// comes from the reorder-immune FEC-group ledger (frx.TakeRaw) instead, and
// both branches must smooth through the same sLossE so the signal is continuous
// across arm/disarm.
func (m *LossMeter) Window(now time.Time, hold time.Duration) (lost, total int) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.drain(now, hold)
	lost, total = m.lost, m.deliv+m.lost
	m.deliv, m.lost = 0, 0
	return
}
