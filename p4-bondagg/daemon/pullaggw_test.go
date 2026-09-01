package main

import (
	"os"
	"reflect"
	"strings"
	"testing"
)

// U36 -- bars on the PULL path's AGG_W contract: "AGG_W unset = no prior".
//
// SCOPE, stated so nothing here is over-read. These bars execute pullNoPrior
// and NewRxEstSet, reflect over PullCore/PullLink, and scan pull.go/pullrun.go
// as text. They do NOT execute runPullClient: it opens
// sockets, binds to devices and needs a peer, and nothing in this repo or in CI
// runs it (HANDOFF: "runPullClient() has never executed anywhere"). What is
// proven is the SHAPE of the per-path state the pull path constructs, and that
// no value of AGG_W moves it. That runPullClient calls pullNoPrior is
// established by reading pullrun.go, not by these bars.
//
// They say nothing about the FROZEN push reference. runClient/runServer still
// carry parseW(env("AGG_W", "20000,15000"), N) and U36 deliberately does not
// edit them (ROADMAP U36). TestPushDefaultIsStillTwoShaped below is the honest
// record of that, and the positive control that keeps the pull bars non-vacuous.

// nSweep spans the N values the daemon is claimed generic over, up to MaxLinks,
// the ceiling frame.go's one-byte pathID imposes on the WIRE -- recorded rather
// than re-accepted here. pullNoPrior itself has no N ceiling.
var nSweep = []int{1, 2, 3, 4, 5, 8, 16, MaxLinks}

// aggWCases spans every way AGG_W can arrive, including the exact literal the
// push default carries. All of them must leave the pull path identical.
var aggWCases = []struct {
	set  bool
	v    string
	what string
}{
	{false, "", "unset"},
	// set-and-empty is the reachable production case, not a hypothetical: every
	// procd stanza passes `AGG_W=$AGG_W` unquoted (deploy/p5/bond-xctl,
	// deploy/p5/init.d/bond-agg, p2-engarde/bondctl), so an agg_env carrying no
	// AGG_W line sets the variable to the empty string rather than leaving it unset.
	{true, "", "set and empty"},
	// the literal the frozen push default carries -- the thing U36 is about.
	{true, "20000,15000", "the push default literal"},
	{true, "10000,10000,10000", "bond-xctl's neutral vector"},
	{true, "1,2,3,4,5,6,7,8", "a fully asymmetric operator vector"},
	{true, "  ,abc,-1,0", "garbage"},
	{true, strings.Repeat("9,", 64), "longer than any N in nSweep"},
}

// setAggW points AGG_W at v for the duration of the test, or removes it
// entirely, restoring whatever the process started with.
func setAggW(t *testing.T, set bool, v string) {
	t.Helper()
	old, had := os.LookupEnv("AGG_W")
	t.Cleanup(func() {
		if had {
			os.Setenv("AGG_W", old)
		} else {
			os.Unsetenv("AGG_W")
		}
	})
	if set {
		os.Setenv("AGG_W", v)
	} else {
		os.Unsetenv("AGG_W")
	}
}

// isFlat reports whether every element equals element 0. For a vector, "equal
// under EVERY permutation of the indices" and "all elements equal" are the same
// statement, so this is the whole of permutation invariance -- not a sample of
// it. Returns the offending index so a failure names the privileged path.
func isFlat(w []float64) (int, bool) {
	for i := range w {
		if w[i] != w[0] {
			return i, false
		}
	}
	return -1, true
}

// TestPullNoPriorIsFlatForAnyN: the pull path's per-path seed is N equal values
// at every N, so no index is privileged and nothing is 2-shaped.
func TestPullNoPriorIsFlatForAnyN(t *testing.T) {
	for _, n := range nSweep {
		w := pullNoPrior(n)
		if len(w) != n {
			t.Fatalf("N=%d: len=%d", n, len(w))
		}
		if i, ok := isFlat(w); !ok {
			t.Fatalf("N=%d: w[%d]=%g != w[0]=%g -- path %d is privileged", n, i, w[i], w[0], i)
		}
	}
}

// TestPullNoPriorIsPermutationInvariant tests what its name claims. The old
// U36 round-1 bar of this name checked only w[i] == w[n-1-i], which is
// reversal symmetry, NOT flatness: [1,2,2,1] passes it while privileging the two
// interior paths. This one applies actual permutations (reversal, a rotation, a
// swap of an interior pair) and requires the vector unchanged under each.
// It carries its own negative control at the bottom: the same permutation set
// applied to [1,2,2,1] MUST move it, so a pass here is not vacuous.
func TestPullNoPriorIsPermutationInvariant(t *testing.T) {
	for _, n := range nSweep {
		w := pullNoPrior(n)
		for name, p := range permutations(n) {
			if !reflect.DeepEqual(permuteVec(w, p), w) {
				t.Fatalf("N=%d: permutation %s changed the vector", n, name)
			}
		}
	}
	// Negative control: [1,2,2,1] survives the reversal check the old bar used,
	// and must NOT survive this one.
	bad := []float64{1, 2, 2, 1}
	moved := false
	for _, p := range permutations(len(bad)) {
		if !reflect.DeepEqual(permuteVec(bad, p), bad) {
			moved = true
		}
	}
	if !moved {
		t.Fatal("control did not fire: [1,2,2,1] passed permutation invariance, so " +
			"the permutation set is too weak to distinguish flat from reversal-symmetric")
	}
	if i, ok := isFlat(bad); ok || i != 1 {
		t.Fatalf("control: isFlat([1,2,2,1]) = (%d,%v), want (1,false)", i, ok)
	}
}

// permutations returns index permutations of length n: reversal, a rotation by
// one, and (for n >= 4) a swap of the two interior elements -- the case that
// distinguishes flatness from reversal symmetry.
func permutations(n int) map[string][]int {
	m := map[string][]int{}
	rev := make([]int, n)
	rot := make([]int, n)
	for i := 0; i < n; i++ {
		rev[i] = n - 1 - i
		rot[i] = (i + 1) % n
	}
	m["reverse"], m["rotate1"] = rev, rot
	if n >= 4 {
		sw := make([]int, n)
		for i := range sw {
			sw[i] = i
		}
		sw[1], sw[2] = 2, 1
		m["swap-interior"] = sw
	}
	return m
}

func permuteVec(w []float64, p []int) []float64 {
	out := make([]float64, len(w))
	for i := range p {
		out[i] = w[p[i]]
	}
	return out
}

// TestPullSeedIsIndependentOfAggW is the regression bar U36 exists for. Every
// way AGG_W can arrive -- unset, empty, the push default's own literal, an
// asymmetric operator vector, garbage, over-long -- must leave the pull path's
// per-path seed byte-identical to the unset case, at every N. Wiring parseW (or
// anything else reading AGG_W) into the pull path fails this.
func TestPullSeedIsIndependentOfAggW(t *testing.T) {
	setAggW(t, false, "")
	base := map[int][]float64{}
	for _, n := range nSweep {
		base[n] = pullNoPrior(n)
	}
	for _, c := range aggWCases {
		setAggW(t, c.set, c.v)
		for _, n := range nSweep {
			got := pullNoPrior(n)
			if !reflect.DeepEqual(got, base[n]) {
				t.Fatalf("AGG_W=%q (%s) at N=%d: seed moved from the unset case", c.v, c.what, n)
			}
			if i, ok := isFlat(got); !ok {
				t.Fatalf("AGG_W=%q (%s) at N=%d: w[%d] privileged", c.v, c.what, n, i)
			}
		}
	}
}

// TestPushDefaultIsStillTwoShaped: POSITIVE CONTROL, and the honest record.
// It runs the push reference's own default literal through the push reference's
// own parser and shows it really does produce a privileged-path vector at the
// client's declared N=4 (docs/INTENT.md:193): [20000, 15000, 10000, 10000].
// It does two jobs. First, without it a green TestPullSeedIsIndependentOfAggW
// could not be told apart from a bar that cannot fail: it proves the literal in
// aggWCases is one that WOULD produce asymmetry if the pull path read it.
// Second, it records EXECUTABLY that U36 did not fix the push reference -- the
// constant is still there, because ROADMAP U36 says the frozen P4 push reference
// is not to be edited for this, and it was not.
//
// It asserts the CURRENT push behaviour, so a future unit that does fix the push
// default will fail here -- deliberately: that unit should delete this bar in
// the same commit, and having to is the point.
func TestPushDefaultIsStillTwoShaped(t *testing.T) {
	w := parseW("20000,15000", 4)
	for i, want := range []float64{20000, 15000, 10000, 10000} {
		if w[i] != want {
			t.Fatalf("push control: w[%d]=%g, want %g", i, w[i], want)
		}
	}
	if _, ok := isFlat(w); ok {
		t.Fatal("push control did not fire: the push default literal parsed FLAT, so " +
			"the pull bars are not distinguishing anything")
	}
}

// TestPullRxEstSetTakesNoPerPathPrior: the one place the pull path feeds a
// per-path vector into shared machinery. NewRxEstSet seeds each link's floor and
// relQF from priorOwd, so an asymmetric seed makes links differ before any sample
// is folded. Bounded, and stated as bounded: the seed governs only that
// pre-first-sample window -- floorUpdate replaces the floor outright on the first
// fold and floorInit gates every consumer until then. Built from pullNoPrior,
// every link must still start identical, at every N.
func TestPullRxEstSetTakesNoPerPathPrior(t *testing.T) {
	setAggW(t, true, "20000,15000")
	for _, n := range nSweep {
		s := NewRxEstSet(pullNoPrior(n))
		if len(s.est) != n {
			t.Fatalf("N=%d: len(est)=%d", n, len(s.est))
		}
		for i := range s.est {
			if s.est[i].floor != s.est[0].floor || s.est[i].relQF != s.est[0].relQF {
				t.Fatalf("N=%d: link %d starts at floor=%g relQF=%g, link 0 at %g/%g",
					n, i, s.est[i].floor, s.est[i].relQF, s.est[0].floor, s.est[0].relQF)
			}
		}
	}
}

// TestPullCoreCarriesNoWeightState: structural bar on pull.go's N-GENERICITY
// claim that "the core needs no per-path weights at all". Reflects over
// PullCore and PullLink and fails on any field whose name reads as a per-path
// capacity prior or rate state -- the shapes AGG_W feeds on the push side
// (Sched.rateKb/floorKb/capHint, CapEst.prior).
//
// LIMITS, so this is not read as more than it is: it is a NAME check on two
// structs. It cannot catch a prior smuggled in under an unrelated name, or one
// held in a package-level var. It catches the obvious reintroduction, which is
// the one that happens, and it makes the claim executable rather than a comment.
func TestPullCoreCarriesNoWeightState(t *testing.T) {
	banned := []string{"weight", "aggw", "prior", "ratekb", "floorkb", "caphint"}
	for _, typ := range []reflect.Type{
		reflect.TypeOf(PullCore{}),
		reflect.TypeOf(PullLink{}),
	} {
		for i := 0; i < typ.NumField(); i++ {
			f := typ.Field(i)
			ln := strings.ToLower(f.Name)
			if ln == "w" {
				t.Fatalf("%s.%s: the pull core has taken a per-path weight vector", typ.Name(), f.Name)
			}
			for _, b := range banned {
				if strings.Contains(ln, b) {
					t.Fatalf("%s.%s: field name reads as a per-path capacity prior (%q); "+
						"the pull core consumes no weights (pull.go N-GENERICITY, ROADMAP U36)",
						typ.Name(), f.Name, b)
				}
			}
		}
	}
	// Non-vacuity control: the matcher must actually reject the push-side field
	// names it is written to catch. If this ever passes trivially the loop above
	// is decoration.
	for _, name := range []string{"w", "W", "rateKb", "floorKb", "capHint", "prior", "aggW", "weights"} {
		ln := strings.ToLower(name)
		hit := ln == "w"
		for _, b := range banned {
			if strings.Contains(ln, b) {
				hit = true
			}
		}
		if !hit {
			t.Fatalf("control: the banned-name matcher does not reject %q, a name it must reject", name)
		}
	}
}

// TestPullSourceDoesNotConsumeAggW: the strongest enforcement available for the
// property U36 asserts, given that runPullClient cannot be executed here (it
// binds sockets to devices and needs a peer). The bars above prove pullNoPrior
// is flat; this one proves the pull path has no OTHER way in for a per-path
// prior, by scanning its own source for the two shapes that would reintroduce
// one: a call to parseW, or AGG_W reaching anything other than the ignore-log.
//
// Comment lines are stripped first, so the many prose mentions of AGG_W and
// parseW in both files' headers are not what is being matched -- only code.
//
// LIMITS: it is a source scan of two named files. It cannot see a prior arriving
// through a third file, or under a different environment variable. It catches
// the direct reintroduction -- copying runClient's `parseW(env("AGG_W", ...))`
// line into the pull path -- which is the one a future edit would actually make.
func TestPullSourceDoesNotConsumeAggW(t *testing.T) {
	for _, f := range []string{"pull.go", "pullrun.go"} {
		b, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("%s: %v", f, err)
		}
		if len(b) < 1000 {
			t.Fatalf("%s: %d bytes -- refusing to pass on a file this small, the "+
				"scan would be vacuous", f, len(b))
		}
		var aggw []string
		sawCode := false
		for i, ln := range strings.Split(string(b), "\n") {
			tr := strings.TrimSpace(ln)
			if tr == "" || strings.HasPrefix(tr, "//") {
				continue
			}
			sawCode = true
			if strings.Contains(tr, "parseW(") {
				t.Fatalf("%s:%d calls parseW -- the pull path has taken a per-path "+
					"weight vector (ROADMAP U36: AGG_W unset = no prior)", f, i+1)
			}
			if strings.Contains(tr, "AGG_W") {
				aggw = append(aggw, tr)
			}
		}
		if !sawCode {
			t.Fatalf("%s: no code lines found -- the comment stripper ate the file", f)
		}
		switch f {
		case "pull.go":
			if len(aggw) != 0 {
				t.Fatalf("pull.go reads AGG_W in code: %q", aggw)
			}
		case "pullrun.go":
			// Drop the diagnostic itself -- the log.Printf line and its string
			// continuations name AGG_W in prose, which is not consuming it.
			var binding []string
			for _, ln := range aggw {
				if strings.Contains(ln, "log.Printf") || strings.HasPrefix(ln, `"`) {
					continue
				}
				binding = append(binding, ln)
			}
			// Exactly one line may mention AGG_W outside the log: the guard. It is
			// a comparison, never an assignment into per-path state.
			if len(binding) != 1 || !strings.Contains(binding[0], `env("AGG_W", "")`) ||
				!strings.Contains(binding[0], `!= ""`) {
				t.Fatalf("pullrun.go: expected exactly one non-log AGG_W code line, the "+
					"ignore-log guard, got %d: %q", len(binding), binding)
			}
		}
	}
}
