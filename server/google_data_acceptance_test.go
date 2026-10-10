package main

import (
	"crypto/sha256"
	"encoding/json"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
)

// Canonical test-only rows; failures report table names, never credential values.
func googleTableRows(t *testing.T, s *SocialStore, table string) []string {
	t.Helper()
	rows, err := s.db.Query(`SELECT * FROM "` + strings.ReplaceAll(table, `"`, `""`) + `"`)
	if err != nil {
		t.Fatal("read table", table, err)
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		t.Fatal(err)
	}
	out := []string{}
	for rows.Next() {
		values, pointers := make([]any, len(cols)), make([]any, len(cols))
		for i := range values {
			pointers[i] = &values[i]
		}
		if err = rows.Scan(pointers...); err != nil {
			t.Fatal(err)
		}
		for i, value := range values {
			if b, ok := value.([]byte); ok {
				values[i] = string(b)
			}
		}
		encoded, err := json.Marshal(values)
		if err != nil {
			t.Fatal(err)
		}
		out = append(out, string(encoded))
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	sort.Strings(out)
	return out
}

func googleTableDigest(t *testing.T, s *SocialStore, table string) [32]byte {
	return sha256.Sum256([]byte(strings.Join(googleTableRows(t, s, table), "\n")))
}

// Catches a binding migration that recreates pets or drops social policies.
func TestGoogleAcceptanceBusinessDataPreserved(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "preserve-a", "alice", "mac-a")
	b := registerTestUser(t, s, "preserve-b", "bob", "mac-b")
	c := registerTestUser(t, s, "preserve-c", "carol", "mac-c")
	makeFriends(t, s, a, b)
	if err := s.SetContactPolicy(a.AccountID, b.AccountID, ContactPolicy{Trusted: true, ShareAgent: true, Note: "fixture-note"}); err != nil {
		t.Fatal(err)
	}
	if _, err := s.RequestFriend(c.AccountID, a.FriendID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.RequestVisit(b.AccountID, a.AccountID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec("UPDATE pets SET style=1,wave_seq=7 WHERE owner_id=?", a.AccountID); err != nil {
		t.Fatal(err)
	}
	tables := []string{"friendships", "friend_requests", "contact_policies", "pets", "visit_requests"}
	before := map[string][32]byte{}
	for _, table := range tables {
		if len(googleTableRows(t, s, table)) == 0 {
			t.Fatal("empty fixture", table)
		}
		before[table] = googleTableDigest(t, s, table)
	}
	proof, err := s.AuthMigrationAccess(a.AccessToken)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.LinkGoogle(proof, GoogleIdentity{"https://accounts.google.com", "preserve-subject", "preserve@example.invalid"}); err != nil {
		t.Fatal(err)
	}
	for _, table := range tables {
		if before[table] != googleTableDigest(t, s, table) {
			t.Fatal("migration changed business table", table)
		}
	}
}

// Catches partial binding commits when a write fails after identity insertion.
func TestGoogleAcceptanceBindingFailureRollsBack(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "rollback-invite", "rollback", "mac-a")
	proof, err := s.AuthMigrationAccess(a.AccessToken)
	if err != nil {
		t.Fatal(err)
	}
	tables := []string{"accounts", "sessions", "recovery_codes", "google_identities", "pets"}
	before := map[string][32]byte{}
	for _, table := range tables {
		before[table] = googleTableDigest(t, s, table)
	}
	if _, err = s.db.Exec(`CREATE TRIGGER fixture_reject_binding BEFORE UPDATE OF auth_method ON accounts BEGIN SELECT RAISE(ABORT,'fixture failure'); END`); err != nil {
		t.Fatal(err)
	}
	if err = s.LinkGoogle(proof, GoogleIdentity{"https://accounts.google.com", "rollback-subject", "rollback@example.invalid"}); err == nil {
		t.Fatal("injected failure not reached")
	}
	for _, table := range tables {
		if before[table] != googleTableDigest(t, s, table) {
			t.Fatal("partial binding persisted", table)
		}
	}
}

// Catches raw auth response caching or identity leakage through contacts.
func TestGoogleAcceptanceCredentialsNotPersistedOrShared(t *testing.T) {
	s, _, h := googleTestService(t)
	status, begin := googleRequest(t, h, "google/begin", googleTestAttempt(), "")
	if status != 200 {
		t.Fatal("begin status", status)
	}
	code := "fixture-unique-authorization-code"
	payload := map[string]any{"attempt_token": begin["attempt_token"], "code": code, "verifier": googleTestVerifier, "nickname": "Fixture"}
	status, auth := googleRequest(t, h, "google/complete", payload, "")
	if status != 200 {
		t.Fatal("complete status", status)
	}
	access, ok := auth["access_token"].(string)
	if !ok {
		t.Fatal("missing access")
	}
	refresh, ok := auth["refresh_token"].(string)
	if !ok {
		t.Fatal("missing refresh")
	}
	// Simulate a lost success response: replay cannot return another session.
	status, _ = googleRequest(t, h, "google/complete", payload, "")
	if status == 200 {
		t.Fatal("complete replay succeeded")
	}
	for _, table := range []string{"accounts", "sessions", "google_identities", "idempotency", "recovery_codes"} {
		for _, row := range googleTableRows(t, s, table) {
			for _, secret := range []string{access, refresh, code, googleTestVerifier, begin["attempt_token"].(string)} {
				if strings.Contains(row, secret) {
					t.Fatal("raw credential persisted", table)
				}
			}
		}
	}
	if len(googleTableRows(t, s, "accounts")) != 1 || len(googleTableRows(t, s, "sessions")) != 1 {
		t.Fatal("replay duplicated state")
	}
	peerID, _, err := s.ResolveGoogle(GoogleIdentity{"https://accounts.google.com", "private-peer-subject", "peer-private@example.invalid"}, "Peer")
	if err != nil {
		t.Fatal(err)
	}
	peer, err := s.Profile(peerID)
	if err != nil {
		t.Fatal(err)
	}
	makeFriends(t, s, AuthResult{AccountID: auth["account_id"].(string)}, AuthResult{AccountID: peerID, FriendID: peer.FriendID})
	r := httptest.NewRequest("GET", "http://petlink.test/v2/contacts", nil)
	r.Header.Set("Authorization", "Bearer "+access)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 200 || !strings.Contains(w.Body.String(), "Peer") {
		t.Fatal("contacts unavailable", w.Code)
	}
	for _, secret := range []string{"one@example.invalid", "fixture-sub", "peer-private@example.invalid", "private-peer-subject", access, refresh} {
		if strings.Contains(w.Body.String(), secret) {
			t.Fatal("private identity leaked through contacts")
		}
	}
}
