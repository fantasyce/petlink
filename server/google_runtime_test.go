package main

import (
	"testing"
	"time"
)

func TestGoogleTakeoverLeaseBarrier(t *testing.T) {
	s := newTestSocial(t)
	id, _, e := s.ResolveGoogle(GoogleIdentity{"https://accounts.google.com", "sub", "a@example.invalid"}, "小满")
	if e != nil {
		t.Fatal(e)
	}
	rt := NewSocialRuntime(s)
	now := time.Now().Add(10 * time.Second)
	rt.now = func() time.Time { return now }
	first, e := rt.IssueGoogleSession(id, "one", false)
	if e != nil {
		t.Fatal(e)
	}
	if e = rt.Connect(id, "one", "socket-one"); e != nil {
		t.Fatal(e)
	}
	snap, e := rt.Snapshot(id, "one", "socket-one", "q1")
	if e != nil || len(snap.Pets) != 1 {
		t.Fatal("initial display", e)
	}
	if _, e = rt.IssueGoogleSession(id, "two", false); e != ErrTakeoverRequired {
		t.Fatal("no confirmation", e)
	}
	if _, e = rt.IssueGoogleSession(id, "two", true); e != nil {
		t.Fatal(e)
	}
	if _, e = s.AuthAccess(first.AccessToken); e == nil {
		t.Fatal("old access works")
	}
	if e = rt.Connect(id, "two", "socket-two"); e != nil {
		t.Fatal(e)
	}
	snap, e = rt.Snapshot(id, "two", "socket-two", "q2")
	if e != nil || len(snap.Pets) != 0 {
		t.Fatal("overlapping display", e)
	}
	if _, e = rt.Snapshot(id, "one", "socket-one", "late"); e == nil {
		t.Fatal("old socket active")
	}
	now = now.Add(6 * time.Second)
	snap, e = rt.Snapshot(id, "two", "socket-two", "q3")
	if e != nil || len(snap.Pets) != 1 {
		t.Fatal("not restored", e)
	}
}
