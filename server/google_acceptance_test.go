package main

import (
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"
)

func TestGoogleAcceptanceMigratedFriendsCapacity(t *testing.T) {
	s := newTestSocial(t)
	accounts := make([]AuthResult, 5)
	for i := range accounts {
		accounts[i] = registerTestUser(t, s, fmt.Sprintf("invite-%d", i), fmt.Sprintf("migrate%d", i), fmt.Sprintf("device-%d", i))
		if i > 0 {
			makeFriends(t, s, accounts[0], accounts[i])
			if err := s.SetContactPolicy(accounts[0].AccountID, accounts[i].AccountID, ContactPolicy{Trusted: true}); err != nil {
				t.Fatal(err)
			}
		}
	}
	rt := NewSocialRuntime(s)
	s.googleOnly.Store(true)
	for i, old := range accounts {
		proof, err := s.AuthMigrationAccess(old.AccessToken)
		if err != nil {
			t.Fatal(err)
		}
		identity := GoogleIdentity{"https://accounts.google.com", fmt.Sprintf("migrated-%d", i), fmt.Sprintf("fixture%d@example.invalid", i)}
		if err = s.LinkGoogle(proof, identity); err != nil {
			t.Fatal(err)
		}
		next, err := rt.IssueGoogleSession(old.AccountID, fmt.Sprintf("device-%d", i), false)
		if err != nil || next.FriendID != old.FriendID {
			t.Fatal("identity changed", err)
		}
		if _, err = s.AuthAccess(old.AccessToken); err == nil {
			t.Fatal("old session retained")
		}
		if _, err = s.AuthAccess(next.AccessToken); err != nil {
			t.Fatal(err)
		}
		accounts[i] = next
	}
	results := make(chan error, 4)
	var wg sync.WaitGroup
	for _, guest := range accounts[1:] {
		wg.Add(1)
		go func(id string) { defer wg.Done(); _, err := s.RequestVisit(id, accounts[0].AccountID); results <- err }(guest.AccountID)
	}
	wg.Wait()
	close(results)
	accepted, full := 0, 0
	for err := range results {
		if err == nil {
			accepted++
		} else if errors.Is(err, ErrHostFull) {
			full++
		} else {
			t.Fatal(err)
		}
	}
	if accepted != 3 || full != 1 {
		t.Fatalf("accepted=%d full=%d", accepted, full)
	}
}

// Uses real store/runtime transactions; no production identities or database.
func TestGoogleAcceptanceTakeoverConcurrent(t *testing.T) {
	s := newTestSocial(t)
	id, _, err := s.ResolveGoogle(GoogleIdentity{"https://accounts.google.com", "concurrent", "fixture@example.invalid"}, "Fixture")
	if err != nil {
		t.Fatal(err)
	}
	rt := NewSocialRuntime(s)
	var wg sync.WaitGroup
	results := make(chan AuthResult, 10)
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			a, e := rt.IssueGoogleSession(id, fmt.Sprintf("device-%d", i), true)
			if e != nil {
				t.Error(e)
				return
			}
			results <- a
		}(i)
	}
	wg.Wait()
	close(results)
	valid := 0
	for a := range results {
		if _, e := s.AuthAccess(a.AccessToken); e == nil {
			valid++
		}
	}
	if valid != 1 {
		t.Fatalf("active sessions=%d", valid)
	}
	p, e := s.Profile(id)
	if e != nil {
		t.Fatal(e)
	}
	// A fresh runtime must respect the startup display barrier even for a valid account.
	restarted := NewSocialRuntime(s)
	if e = restarted.Connect(id, p.ActiveDevice, "restart-socket"); e != nil {
		t.Fatal(e)
	}
	snap, e := restarted.Snapshot(id, p.ActiveDevice, "restart-socket", "before-barrier")
	if e != nil || len(snap.Pets) != 0 {
		t.Fatalf("restart barrier: %v %d", e, len(snap.Pets))
	}
	restarted.now = func() time.Time { return time.Now().Add(7 * time.Second) }
	snap, e = restarted.Snapshot(id, p.ActiveDevice, "restart-socket", "after-barrier")
	if e != nil || len(snap.Pets) != 1 {
		t.Fatalf("restart recovery: %v %d", e, len(snap.Pets))
	}
}

func TestGoogleAcceptanceExpiredLegacyProof(t *testing.T) {
	s, _, h := googleTestService(t)
	a := registerTestUser(t, s, "expired-invite", "expireduser", "legacy-device")
	if _, e := s.db.Exec("UPDATE sessions SET access_expires=0 WHERE account_id=?", a.AccountID); e != nil {
		t.Fatal(e)
	}
	if _, e := s.AuthAccess(a.AccessToken); e != ErrUnauthorized {
		t.Fatal("expired access", e)
	}
	if _, e := s.Refresh(a.RefreshToken); e != ErrMigrationRequired {
		t.Fatal("refresh must require migration", e)
	}
	status, out := googleRequest(t, h, "migration/prove", map[string]any{"username": "expireduser", "password": "correct horse battery staple", "device_id": "legacy-device"}, "")
	if status != 200 || out["ticket"] == nil {
		t.Fatal(status, out)
	}
	var active int
	if e := s.db.QueryRow("SELECT count(*) FROM sessions WHERE account_id=?", a.AccountID).Scan(&active); e != nil || active != 1 {
		t.Fatal("proof created a session", active, e)
	}
}
