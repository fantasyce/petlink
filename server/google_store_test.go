package main

import (
	"database/sql"
	"path/filepath"
	"sync"
	"testing"
)

func TestGoogleSchemaMigration(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.db")
	db, e := sql.Open("sqlite", path)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = db.Exec(socialSchema); e != nil {
		t.Fatal(e)
	}
	db.Close()
	s, e := OpenSocialStore(path)
	if e != nil {
		t.Fatal(e)
	}
	defer s.Close()
	if e = s.MigrateGoogleSchema(); e != nil {
		t.Fatal(e)
	}
	if e = s.MigrateGoogleSchema(); e != nil {
		t.Fatal("not idempotent", e)
	}
	var version int
	if e = s.db.QueryRow("SELECT version FROM auth_schema_version WHERE id=1").Scan(&version); e != nil || version != 2 {
		t.Fatal(version, e)
	}
}
func TestGoogleAccountConcurrentCreate(t *testing.T) {
	s := newTestSocial(t)
	identity := GoogleIdentity{Issuer: "https://accounts.google.com", Subject: "google-fixture", Email: "one@example.invalid"}
	var wg sync.WaitGroup
	results := make(chan string, 10)
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			id, _, e := s.ResolveGoogle(identity, "小满")
			if e != nil {
				t.Error(e)
			}
			results <- id
		}()
	}
	wg.Wait()
	close(results)
	first := ""
	for id := range results {
		if first == "" {
			first = id
		}
		if id != first {
			t.Fatal("duplicate account")
		}
	}
	var n int
	s.db.QueryRow("SELECT count(*) FROM accounts").Scan(&n)
	if n != 1 {
		t.Fatal(n)
	}
	s.db.QueryRow("SELECT count(*) FROM pets").Scan(&n)
	if n != 1 {
		t.Fatal(n)
	}
	identity.Email = "changed@example.invalid"
	id, created, e := s.ResolveGoogle(identity, "")
	if e != nil || created || id != first {
		t.Fatal("email change lost identity", e)
	}
	identity.Subject = "different-google"
	id, created, e = s.ResolveGoogle(identity, "另一个")
	if e != nil || !created || id == first {
		t.Fatal("merged by email", e)
	}
}
func TestGoogleLinkPreservesIdentity(t *testing.T) {
	for _, method := range []string{"password", "recovery", "session"} {
		t.Run(method, func(t *testing.T) {
			s := newTestSocial(t)
			a := registerTestUser(t, s, "a-invite", "alice", "mac-a")
			b := registerTestUser(t, s, "b-invite", "bob", "mac-b")
			lo, hi := pairIDs(a.AccountID, b.AccountID)
			s.db.Exec("INSERT INTO friendships(user_low,user_high,created_at) VALUES(?,?,1)", lo, hi)
			s.db.Exec("UPDATE pets SET style=1 WHERE owner_id=?", a.AccountID)
			var proof GoogleProof
			var e error
			switch method {
			case "password":
				proof, e = s.ProveLegacy("alice", "correct horse battery staple", "")
			case "recovery":
				proof, e = s.ProveLegacy("alice", "", a.RecoveryCode)
			case "session":
				proof, e = s.AuthMigrationAccess(a.AccessToken)
			}
			if e != nil {
				t.Fatal(e)
			}
			identity := GoogleIdentity{Issuer: "https://accounts.google.com", Subject: "fixture-sub", Email: "one@example.invalid"}
			if e = s.LinkGoogle(proof, identity); e != nil {
				t.Fatal(e)
			}
			p, e := s.Profile(a.AccountID)
			if e != nil || p.FriendID != a.FriendID || p.Nickname != "alice" || !s.friends(a.AccountID, b.AccountID) {
				t.Fatal("business identity changed", e)
			}
			var style int
			s.db.QueryRow("SELECT style FROM pets WHERE owner_id=?", a.AccountID).Scan(&style)
			if style != 1 {
				t.Fatal("style lost")
			}
			if _, _, e = s.authenticatePassword("alice", "correct horse battery staple"); e == nil {
				t.Fatal("old password still usable")
			}
			if _, e = s.ProveLegacy("alice", "", a.RecoveryCode); e == nil {
				t.Fatal("old recovery usable")
			}
			if _, e = s.AuthAccess(a.AccessToken); e == nil {
				t.Fatal("old session usable")
			}
		})
	}
}
func TestGoogleLinkRaceAndReplay(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "a", "alice", "mac-a")
	registerTestUser(t, s, "b", "bob", "mac-b")
	p, e := s.ProveLegacy("alice", "", a.RecoveryCode)
	if e != nil {
		t.Fatal(e)
	}
	id := GoogleIdentity{Issuer: "https://accounts.google.com", Subject: "taken-sub", Email: "one@example.invalid"}
	pb, _ := s.ProveLegacy("bob", "correct horse battery staple", "")
	if e = s.LinkGoogle(pb, id); e != nil {
		t.Fatal(e)
	}
	if e = s.LinkGoogle(p, id); e == nil {
		t.Fatal("identity conflict accepted")
	}
	// A rejected binding must be atomic: no account, identity, or session theft.
	profile, e := s.Profile(a.AccountID)
	if e != nil || profile.FriendID != a.FriendID || profile.Nickname != "alice" {
		t.Fatal("conflict modified legacy profile", e)
	}
	if _, e = s.AuthAccess(a.AccessToken); e != nil {
		t.Fatal("conflict revoked legacy session", e)
	}
	if _, _, e = s.authenticatePassword("alice", "correct horse battery staple"); e != nil {
		t.Fatal("conflict invalidated legacy password", e)
	}
	owner, created, e := s.ResolveGoogle(id, "")
	if e != nil || created || owner != pb.AccountID {
		t.Fatal("conflict transferred Google identity", e)
	}
	if _, e = s.ProveLegacy("alice", "", a.RecoveryCode); e != nil {
		t.Fatal("failed link consumed recovery", e)
	}
	id.Subject = "free-sub"
	var wg sync.WaitGroup
	errs := make(chan error, 2)
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); errs <- s.LinkGoogle(p, id) }()
	}
	wg.Wait()
	close(errs)
	success := 0
	for e := range errs {
		if e == nil {
			success++
		}
	}
	if success != 1 {
		t.Fatal("multiple link commits", success)
	}
}
