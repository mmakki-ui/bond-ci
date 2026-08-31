package main

import "sync/atomic"

func atomicAdd(p *uint64, v uint64) { atomic.AddUint64(p, v) }

func min64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}
