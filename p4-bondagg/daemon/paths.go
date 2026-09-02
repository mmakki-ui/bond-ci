package main

import (
	"net"
	"os"
	"sync"
	"syscall"
	"time"
)

func nowMS() uint32 { return uint32(time.Now().UnixMilli() & 0xFFFFFFFF) }

// device-bound UDP socket (client side), engarde-proven mechanism
func devConn(ifname string) (*net.UDPConn, error) {
	s, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM, syscall.IPPROTO_UDP)
	if err != nil {
		return nil, err
	}
	syscall.SetsockoptInt(s, syscall.SOL_SOCKET, syscall.SO_REUSEADDR, 1)
	if ifname != "" {
		if err := syscall.SetsockoptString(s, syscall.SOL_SOCKET, syscall.SO_BINDTODEVICE, ifname); err != nil {
			syscall.Close(s)
			return nil, err
		}
	}
	lsa := syscall.SockaddrInet4{Port: 0}
	if err := syscall.Bind(s, &lsa); err != nil {
		syscall.Close(s)
		return nil, err
	}
	f := os.NewFile(uintptr(s), "")
	c, err := net.FilePacketConn(f)
	f.Close()
	if err != nil {
		return nil, err
	}
	return c.(*net.UDPConn), nil
}

// OWD tracker: per-path relative one-way delay via header timestamps.
// hold = clamp(spread + 3*jitter + 250, HoldMin, HoldMax). N-path: spread is the
// max-min over all initialized paths; jitter is the max over paths.
type OWD struct {
	mu   sync.Mutex
	rel  []float64 // ewma of (arrival - txstamp), clock-offset included
	jit  []float64
	init []bool
}

func NewOWD(n int) *OWD {
	return &OWD{rel: make([]float64, n), jit: make([]float64, n), init: make([]bool, n)}
}

func (o *OWD) Sample(path int, tsms uint32) {
	d := float64(int32(nowMS() - tsms)) // relative; offset cancels in spread
	o.mu.Lock()
	defer o.mu.Unlock()
	if !o.init[path] {
		o.rel[path] = d
		o.init[path] = true
		return
	}
	prev := o.rel[path]
	o.rel[path] = prev*0.9 + d*0.1
	dev := d - prev
	if dev < 0 {
		dev = -dev
	}
	o.jit[path] = o.jit[path]*0.9 + dev*0.1
}

func (o *OWD) Hold(min, max time.Duration) time.Duration {
	o.mu.Lock()
	defer o.mu.Unlock()
	lo, hi := 0.0, 0.0
	haveSpread := false
	j := 0.0
	for p := range o.rel {
		// EIF: parked (STANDBY) paths carry no data -> never init; skip them so
		// they don't pin the hold at max. Cross-path reorder only spans the paths
		// actually delivering. (N=2 both-active is unchanged.)
		if !o.init[p] {
			continue
		}
		if !haveSpread || o.rel[p] < lo {
			lo = o.rel[p]
		}
		if !haveSpread || o.rel[p] > hi {
			hi = o.rel[p]
		}
		haveSpread = true
		if o.jit[p] > j {
			j = o.jit[p]
		}
	}
	if !haveSpread {
		return max // warm-up: nothing learned yet
	}
	spread := hi - lo
	h := time.Duration(spread+3*j+250) * time.Millisecond // +250: estimator probe-queue allowance (covers BigQ band)
	if h < min {
		h = min
	}
	if h > max {
		h = max
	}
	return h
}
