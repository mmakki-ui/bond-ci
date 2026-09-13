package main

import "fmt"

func fmtSscan(s string, v *int) (int, error) { return fmt.Sscan(s, v) }
