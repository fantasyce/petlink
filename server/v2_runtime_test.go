package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func makeFriends(t *testing.T, s *SocialStore, a, b AuthResult) {
	t.Helper()
	r, e := s.RequestFriend(a.AccountID, b.FriendID)
	if e != nil {
		t.Fatal(e)
	}
	if e = s.RespondFriend(b.AccountID, r.ID, true); e != nil {
		t.Fatal(e)
	}
}

func TestEmptySnapshotUsesArraysNotNull(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "ia", "alice", "mac-a")
	rt := NewSocialRuntime(s)
	rt.readyAt = time.Now()
	if e := rt.Connect(a.AccountID, "mac-a", "sa"); e != nil {
		t.Fatal(e)
	}
	snap, e := rt.Snapshot(a.AccountID, "mac-a", "sa", "one")
	if e != nil {
		t.Fatal(e)
	}
	raw, _ := json.Marshal(snap)
	for _, field := range []string{"contacts", "friend_requests", "visit_requests", "outgoing_visits"} {
		if strings.Contains(string(raw), `"`+field+`":null`) {
			t.Fatalf("%s must be []: %s", field, raw)
		}
	}
	var persistedLeases int
	_ = s.db.QueryRow(`SELECT count(*) FROM display_leases`).Scan(&persistedLeases)
	if persistedLeases != 0 {
		t.Fatalf("short display lease was persisted: %d", persistedLeases)
	}
}

func TestSocialRuntimeTransfersOnlyAfterSourceHide(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "ia", "alice", "mac-a")
	b := registerTestUser(t, s, "ib", "bob", "mac-b")
	makeFriends(t, s, a, b)
	if e := s.SetContactPolicy(b.AccountID, a.AccountID, ContactPolicy{Trusted: true}); e != nil {
		t.Fatal(e)
	}
	now := time.Unix(2_000_000_000, 0)
	rt := NewSocialRuntime(s)
	rt.now = func() time.Time { return now }
	rt.readyAt = now
	if e := rt.Connect(a.AccountID, "mac-a", "sa"); e != nil {
		t.Fatal(e)
	}
	if e := rt.Connect(b.AccountID, "mac-b", "sb"); e != nil {
		t.Fatal(e)
	}
	initial, e := rt.Snapshot(a.AccountID, "mac-a", "sa", "one")
	if e != nil || len(initial.Pets) != 1 {
		t.Fatalf("initial=%#v err=%v", initial, e)
	}
	v, e := rt.RequestVisit(a.AccountID, b.AccountID)
	if e != nil || v.Status != "accepted" {
		t.Fatalf("visit=%#v err=%v", v, e)
	}
	departing, e := rt.Snapshot(a.AccountID, "mac-a", "sa", "two")
	if e != nil || len(departing.Hides) != 1 || len(departing.Pets) != 0 {
		t.Fatalf("departing=%#v err=%v", departing, e)
	}
	before, e := rt.Snapshot(b.AccountID, "mac-b", "sb", "three")
	if e != nil || len(before.Pets) != 1 {
		t.Fatalf("host showed guest before hide: %#v err=%v", before, e)
	}
	if e = rt.AckHide(a.AccountID, "mac-a", "sa", a.AccountID, departing.Hides[0].Revision); e != nil {
		t.Fatal(e)
	}
	after, e := rt.Snapshot(b.AccountID, "mac-b", "sb", "four")
	if e != nil || len(after.Pets) != 2 {
		t.Fatalf("guest not shown after hide: %#v err=%v", after, e)
	}
}

func TestOldDeviceCannotReceiveDisplayLease(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "ia", "alice", "mac-a")
	rt := NewSocialRuntime(s)
	rt.readyAt = time.Now()
	if _, e := s.Takeover(TakeoverInput{Username: "alice", Password: "correct horse battery staple", DeviceID: "mac-new"}); e != nil {
		t.Fatal(e)
	}
	if e := rt.Connect(a.AccountID, "mac-a", "old"); e != ErrDeviceReplaced {
		t.Fatalf("old device connect: %v", e)
	}
}

func TestRuntimeRestartCooldownPreventsImmediateDisplay(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "ia", "alice", "mac-a")
	now := time.Unix(2_000_000_000, 0)
	rt := NewSocialRuntime(s)
	rt.now = func() time.Time { return now }
	rt.readyAt = now
	_ = rt.Connect(a.AccountID, "mac-a", "sa")
	if snap, e := rt.Snapshot(a.AccountID, "mac-a", "sa", "one"); e != nil || len(snap.Pets) != 1 {
		t.Fatalf("first=%#v err=%v", snap, e)
	}
	restarted := NewSocialRuntime(s)
	restarted.now = func() time.Time { return now }
	restarted.readyAt = now.Add(6 * time.Second)
	_ = restarted.Connect(a.AccountID, "mac-a", "new")
	if snap, e := restarted.Snapshot(a.AccountID, "mac-a", "new", "two"); e != nil || len(snap.Pets) != 0 {
		t.Fatalf("restart showed early=%#v err=%v", snap, e)
	}
	now = now.Add(7 * time.Second)
	if snap, e := restarted.Snapshot(a.AccountID, "mac-a", "new", "three"); e != nil || len(snap.Pets) != 1 {
		t.Fatalf("restart did not recover=%#v err=%v", snap, e)
	}
}

func TestRuntimeRejectsVisitsWhileHostPaused(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "ia", "alice", "mac-a")
	b := registerTestUser(t, s, "ib", "bob", "mac-b")
	makeFriends(t, s, a, b)
	rt := NewSocialRuntime(s)
	rt.readyAt = time.Now()
	if e := rt.Connect(a.AccountID, "mac-a", "sa"); e != nil {
		t.Fatal(e)
	}
	if e := rt.Connect(b.AccountID, "mac-b", "sb"); e != nil {
		t.Fatal(e)
	}
	if e := rt.SetAccepting(b.AccountID, false); e != nil {
		t.Fatal(e)
	}
	if _, e := rt.RequestVisit(a.AccountID, b.AccountID); e != ErrHostPaused {
		t.Fatalf("paused host error=%v", e)
	}
	view, e := rt.Snapshot(a.AccountID, "mac-a", "sa", "paused-status")
	if e != nil || len(view.Contacts) != 1 || view.Contacts[0].Accepting {
		t.Fatalf("paused state not projected: %#v %v", view.Contacts, e)
	}
	if e = rt.SetAccepting(b.AccountID, true); e != nil {
		t.Fatal(e)
	}
	view, e = rt.Snapshot(a.AccountID, "mac-a", "sa", "resumed-status")
	if e != nil || len(view.Contacts) != 1 || !view.Contacts[0].Accepting {
		t.Fatalf("resumed state not projected: %#v %v", view.Contacts, e)
	}
}

func TestDisconnectReturnsVisitingPetAndReleasesCapacity(t *testing.T) {
	s := newTestSocial(t)
	guest := registerTestUser(t, s, "ia", "alice", "mac-a")
	host := registerTestUser(t, s, "ib", "bob", "mac-b")
	makeFriends(t, s, guest, host)
	if e := s.SetContactPolicy(host.AccountID, guest.AccountID, ContactPolicy{Trusted: true}); e != nil {
		t.Fatal(e)
	}
	rt := NewSocialRuntime(s)
	rt.readyAt = time.Now()
	_ = rt.Connect(guest.AccountID, "mac-a", "sa")
	_ = rt.Connect(host.AccountID, "mac-b", "sb")
	visit, e := rt.RequestVisit(guest.AccountID, host.AccountID)
	if e != nil || visit.Status != "accepted" {
		t.Fatalf("visit=%#v err=%v", visit, e)
	}
	rt.Disconnect(guest.AccountID, "sa")
	var target, phase, status string
	if e = s.db.QueryRow(`SELECT target_id,phase FROM pets WHERE owner_id=?`, guest.AccountID).Scan(&target, &phase); e != nil {
		t.Fatal(e)
	}
	if e = s.db.QueryRow(`SELECT status FROM visit_requests WHERE id=?`, visit.ID).Scan(&status); e != nil {
		t.Fatal(e)
	}
	if target != guest.AccountID || phase != "travel" || status != "completed" {
		t.Fatalf("target=%q phase=%q status=%q", target, phase, status)
	}
}

func TestRapidWavesKeepSequenceAndShortExpiry(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "ia", "alice", "mac-a")
	now := time.Unix(2_000_000_000, 0)
	rt := NewSocialRuntime(s)
	rt.now = func() time.Time { return now }
	rt.readyAt = now
	_ = rt.Connect(a.AccountID, "mac-a", "sa")
	if e := rt.Wave(a.AccountID); e != nil {
		t.Fatal(e)
	}
	if e := rt.Wave(a.AccountID); e != nil {
		t.Fatal(e)
	}
	snap, e := rt.Snapshot(a.AccountID, "mac-a", "sa", "wave")
	if e != nil || snap.Own.WaveSequence != 2 || snap.Own.WaveExpiresAt == nil || !snap.Own.WaveExpiresAt.Equal(now.Add(3*time.Second)) {
		t.Fatalf("snapshot=%#v err=%v", snap.Own, e)
	}
	now = now.Add(4 * time.Second)
	snap, e = rt.Snapshot(a.AccountID, "mac-a", "sa", "expired")
	if e != nil || snap.Own.WaveExpiresAt != nil {
		t.Fatalf("expired wave=%#v err=%v", snap.Own, e)
	}
}
