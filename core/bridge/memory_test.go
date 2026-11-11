package main

import "testing"

func TestProcessRSS(t *testing.T) {
	if v := processRSS(); v < 1<<20 || v > 1<<40 {
		t.Fatalf("implausible RSS %d", v)
	}
}
