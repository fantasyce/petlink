package main

import (
	"path/filepath"
	"testing"
)

func TestLegacyIdentityCanBeClaimedOnce(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.db")
	h, e := OpenHub(path)
	if e != nil {
		t.Fatal(e)
	}
	if e = h.AddInvitation("a", "A", "code-a"); e != nil {
		t.Fatal(e)
	}
	if e = h.AddInvitation("b", "B", "code-b"); e != nil {
		t.Fatal(e)
	}
	_, tokenA, e := h.Pair("code-a")
	if e != nil {
		t.Fatal(e)
	}
	_, _, e = h.Pair("code-b")
	if e != nil {
		t.Fatal(e)
	}
	if e = h.Act("b", "", Command{}); e == nil {
		_ = e
	}
	h.Close()
	s, e := OpenSocialStore(path)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	if e = s.MigrateLegacy(); e != nil {
		t.Fatal(e)
	}
	r, e := s.ClaimLegacy(ClaimInput{LegacyToken: tokenA, Username: "alice", Password: "correct horse battery staple", Nickname: "Alice", DeviceID: "mac-a"})
	if e != nil {
		t.Fatal(e)
	}
	if r.AccessToken == "" || r.RecoveryCode == "" {
		t.Fatalf("claim=%#v", r)
	}
	if _, e = s.ClaimLegacy(ClaimInput{LegacyToken: tokenA, Username: "alice2", Password: "another secure password", Nickname: "Alice", DeviceID: "mac-x"}); e != ErrUnauthorized {
		t.Fatalf("claim replay: %v", e)
	}
	var style int
	if e = s.db.QueryRow(`SELECT style FROM pets WHERE owner_id=?`, r.AccountID).Scan(&style); e != nil {
		t.Fatal(e)
	}
}
