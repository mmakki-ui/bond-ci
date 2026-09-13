package main

import (
	"log"
	"os"
	"strings"
	"time"
)

// U128 (ADR-002 as amended by U127). This file used to be 644 lines: the EIF
// PUSH client and push server entry points, and parseW. BOTH ENTRY POINTS ARE
// DELETED -- they were the only callers of the EIF picker, the Estr/CapEst
// estimator pair, the FEC TX/RX and its tier controller, and the AIMD scheduler
// constructor, and both shipped procd stanzas launch AGG_MODE=pull-client
// (U111), so nothing on a box reached them. The push tree
// is preserved as the annotated tag `eif-push-reference` on 87cbf42; restore it
// with `git checkout eif-push-reference -- p4-bondagg/daemon`.
//
// WHAT SURVIVED HERE AND WHY, EACH BECAUSE A PULL-SIDE FILE STILL READS IT:
//   - env: pullrun.go, pull.go, lightning.go, auth.go, discover.go.
//   - the timer constants: HoldMin/HoldMax (pullrun.go:236,306,441,500),
//     PingIval (pullrun.go:662, pull.go:1440,1474, lightning.go:661),
//     LossIval (pullrun.go:521), DeadIval (auth.go:132 ReopenFloor,
//     cap.go:1193,1341, pullrun.go:498). SuspectIval has no reader left; it is
//     kept inside the block because the block is the wire-timing table and a
//     hole in it is harder to read than an unused entry.
//   - pongLen: pullrun.go:373.
//   - parseW: pullaggw_test.go:209 (TestPushDefaultIsStillTwoShaped) calls it
//     as the POSITIVE CONTROL for U36's pull bars -- it is what proves the
//     AGG_W literal would produce an asymmetric vector if the pull path read
//     it. Deleting parseW would make that control vacuous, so per the U128
//     rule a symbol a pull file references STAYS. pullaggw_test.go:318's
//     tripwire (pull.go/pullrun.go must not call parseW) is unaffected.

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

const (
	HoldMin     = 150 * time.Millisecond
	HoldMax     = 350 * time.Millisecond
	PingIval    = 100 * time.Millisecond
	LossIval    = 500 * time.Millisecond
	SuspectIval = 300 * time.Millisecond
	// DeadIval: pong/frame age past which a path is declared DEAD (ineligible for
	// Pick + backup). Aligned to the FSM's validated DEAD_IVAL=600ms (nsched:368);
	// the prior 1500ms delayed failover ~900ms past the model's tuned point (#6).
	DeadIval = 600 * time.Millisecond
)

func main() {
	mode := env("AGG_MODE", "")
	switch mode {
	case "pull-client":
		// U7/E2a: the PULL core (pull.go + pullrun.go). The only datapath this
		// binary has, and the mode both shipped procd stanzas pass (U111).
		runPullClient()
	case "client", "server":
		// REFUSE LOUDLY rather than fall through to the default's generic line.
		// These two named a datapath that no longer exists in this binary, and a
		// stale init script or an operator's muscle memory will still ask for
		// them; saying exactly where the code went is the difference between a
		// one-line fix and a bisect.
		log.Fatalf("AGG_MODE=%s was the EIF push datapath and it is DELETED "+
			"(ADR-002 / U128). Use AGG_MODE=pull-client. The push tree is "+
			"preserved at git tag eif-push-reference: "+
			"git checkout eif-push-reference -- p4-bondagg/daemon", mode)
	default:
		log.Fatal("AGG_MODE=pull-client required")
	}
}

// pongLen is the R3 pong payload: [lp, qb, od, jt, dHi, dLo].
const pongLen = 6

// parseW parses an N-CSV of per-path weight floors (kb/s); missing/garbage
// entries default to 10000. NO SHIPPED CODE PATH CALLS IT any more (the push
// entry points that did are deleted): its one live caller is the push control
// bar named in this file's header. It is retained, not re-implemented.
func parseW(s string, n int) []float64 {
	parts := strings.Split(s, ",")
	w := make([]float64, n)
	for i := 0; i < n; i++ {
		w[i] = 10000
		if i < len(parts) {
			var x int
			if _, err := fmtSscan(parts[i], &x); err == nil && x > 0 {
				w[i] = float64(x)
			}
		}
	}
	return w
}
