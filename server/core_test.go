package main

import (
	"testing"
	"time"
)

func fixture(t *testing.T) (*Hub, *time.Time) {
	t.Helper()
	now := time.Unix(1800000000, 0)
	h, err := OpenHub(t.TempDir() + "/state.db")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { h.Close() })
	h.now = func() time.Time { return now }
	h.readyAt = now
	h.AddUser("a", "A", "token-a")
	h.AddUser("b", "B", "token-b")
	h.Connect("a", "sa")
	h.Connect("b", "sb")
	return h, &now
}
func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
func TestAuthorizationAndTransfer(t *testing.T) {
	h, _ := fixture(t)
	if h.Act("a", "sa", Command{Action: "visit", Peer: "b"}) == nil {
		t.Fatal("unauthorized visit")
	}
	must(t, h.Act("b", "sb", Command{Action: "allow", Peer: "a", Enabled: true}))
	s := h.Snapshot("a", "sa")
	if len(s.Pets) != 1 {
		t.Fatal("home missing")
	}
	must(t, h.Act("a", "sa", Command{Action: "visit", Peer: "b"}))
	s = h.Snapshot("a", "sa")
	if len(s.Pets) != 0 || len(s.Hides) != 1 {
		t.Fatal("source must hide")
	}
	if len(h.Snapshot("b", "sb").Pets) != 1 {
		t.Fatal("destination displayed too early")
	}
	must(t, h.Act("a", "sa", Command{Action: "ack", Pet: "a", Revision: s.Hides[0].Revision}))
	if len(h.Snapshot("b", "sb").Pets) != 2 {
		t.Fatal("visitor did not arrive")
	}
	must(t, h.Act("a", "sa", Command{Action: "recall"}))
	s = h.Snapshot("b", "sb")
	must(t, h.Act("b", "sb", Command{Action: "ack", Pet: "a", Revision: s.Hides[0].Revision}))
	if len(h.Snapshot("a", "sa").Pets) != 1 {
		t.Fatal("not home")
	}
}
func TestLeaseExpiryAndStaleAck(t *testing.T) {
	h, now := fixture(t)
	h.Snapshot("a", "sa")
	must(t, h.Act("b", "sb", Command{Action: "allow", Peer: "a", Enabled: true}))
	must(t, h.Act("a", "sa", Command{Action: "visit", Peer: "b"}))
	if h.Act("a", "sa", Command{Action: "ack", Pet: "a", Revision: -1}) == nil {
		t.Fatal("stale ack accepted")
	}
	*now = now.Add(6 * time.Second)
	h.Connect("b", "sb")
	if len(h.Snapshot("b", "sb").Pets) != 2 {
		t.Fatal("expiry should finish transfer")
	}
}
func TestRevokeReturnsGuest(t *testing.T) {
	h, now := fixture(t)
	must(t, h.Act("b", "sb", Command{Action: "allow", Peer: "a", Enabled: true}))
	must(t, h.Act("a", "sa", Command{Action: "visit", Peer: "b"}))
	h.Snapshot("b", "sb")
	must(t, h.Act("b", "sb", Command{Action: "allow", Peer: "a", Enabled: false}))
	*now = now.Add(6 * time.Second)
	h.Connect("a", "sa")
	if len(h.Snapshot("a", "sa").Pets) != 1 {
		t.Fatal("revoke failed to return")
	}
}
func TestReconnectCannotDuplicateDisplay(t *testing.T) {
	h, now := fixture(t)
	h.Snapshot("a", "sa")
	h.Connect("a", "new")
	if len(h.Snapshot("a", "new").Pets) != 0 {
		t.Fatal("new session stole active lease")
	}
	if h.Act("a", "sa", Command{Action: "recall"}) == nil {
		t.Fatal("old session authorized")
	}
	*now = now.Add(6 * time.Second)
	if len(h.Snapshot("a", "new").Pets) != 1 {
		t.Fatal("new session did not recover")
	}
}
func TestDisconnectReturnsVisitor(t *testing.T) {
	h, now := fixture(t)
	must(t, h.Act("b", "sb", Command{Action: "allow", Peer: "a", Enabled: true}))
	must(t, h.Act("a", "sa", Command{Action: "visit", Peer: "b"}))
	h.Snapshot("b", "sb")
	h.Disconnect("b", "sb")
	*now = now.Add(6 * time.Second)
	if len(h.Snapshot("a", "sa").Pets) != 1 {
		t.Fatal("offline host stranded pet")
	}
}
func TestPersistentState(t *testing.T) {
	path := t.TempDir() + "/state.db"
	h, e := OpenHub(path)
	must(t, e)
	must(t, h.AddUser("a", "A", "secret"))
	h.Close()
	h, e = OpenHub(path)
	must(t, e)
	defer h.Close()
	if h.Auth("secret") != "a" {
		t.Fatal("auth did not survive restart")
	}
	if h.Auth("wrong") != "" {
		t.Fatal("bad credential accepted")
	}
}

func TestRestartHoldsDisplayThenReturnsOfflineGuest(t *testing.T) {
	path := t.TempDir() + "/state.db"
	h, e := OpenHub(path)
	must(t, e)
	must(t, h.AddUser("a", "A", "token-a"))
	must(t, h.AddUser("b", "B", "token-b"))
	now := time.Now()
	h.now = func() time.Time { return now }
	h.readyAt = now
	h.Connect("a", "sa")
	h.Connect("b", "sb")
	must(t, h.Act("b", "sb", Command{Action: "allow", Peer: "a", Enabled: true}))
	must(t, h.Act("a", "sa", Command{Action: "visit", Peer: "b"}))
	if len(h.Snapshot("b", "sb").Pets) != 2 {
		t.Fatal("fixture missing visitor")
	}
	h.Close()
	restored, e := OpenHub(path)
	must(t, e)
	defer restored.Close()
	restored.now = func() time.Time { return now }
	restored.readyAt = now.Add(6 * time.Second)
	restored.Connect("a", "new-a")
	if len(restored.Snapshot("a", "new-a").Pets) != 0 {
		t.Fatal("restart ignored cooldown")
	}
	now = now.Add(7 * time.Second)
	s := restored.Snapshot("a", "new-a")
	if s.Own.Phase != "home" || len(s.Pets) != 1 {
		t.Fatal("restart did not restore offline visitor home")
	}
}

func TestStorageFailureStopsDisplay(t *testing.T) {
	h, _ := fixture(t)
	h.db.Close()
	if len(h.Snapshot("a", "sa").Pets) != 0 {
		t.Fatal("display permitted without durable state")
	}
	if h.Auth("token-a") != "" {
		t.Fatal("failed storage must close authentication")
	}
}

func TestWrongSessionAckAndInvalidStyle(t *testing.T) {
	h, _ := fixture(t)
	h.Snapshot("a", "sa")
	must(t, h.Act("b", "sb", Command{Action: "allow", Peer: "a", Enabled: true}))
	must(t, h.Act("a", "sa", Command{Action: "visit", Peer: "b"}))
	s := h.Snapshot("a", "sa")
	if h.Act("b", "sb", Command{Action: "ack", Pet: "a", Revision: s.Hides[0].Revision}) == nil {
		t.Fatal("host acknowledged owner's display")
	}
	if h.Act("a", "sa", Command{Action: "style", Style: 999}) == nil {
		t.Fatal("unknown style accepted")
	}
}
