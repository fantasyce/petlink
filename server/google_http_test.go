package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

type googleFixtureExchanger struct {
	identity GoogleIdentity
	err      error
}

func (f googleFixtureExchanger) Exchange(context.Context, GoogleExchangeInput) (GoogleIdentity, error) {
	return f.identity, f.err
}
func googleTestService(t *testing.T) (*SocialStore, *GoogleAuthService, http.Handler) {
	s := newTestSocial(t)
	rt := NewSocialRuntime(s)
	a := &GoogleAuthService{Store: s, Runtime: rt, Attempts: newGoogleAttempts("test-client", time.Now), Provider: googleFixtureExchanger{identity: GoogleIdentity{"https://accounts.google.com", "fixture-sub", "one@example.invalid"}}, MigrationOpen: true}
	return s, a, GoogleHandler(a)
}
func googleRequest(t *testing.T, h http.Handler, path string, body any, token string) (int, map[string]any) {
	t.Helper()
	b, e := json.Marshal(body)
	if e != nil {
		t.Fatal(e)
	}
	r := httptest.NewRequest("POST", "http://petlink.test/v2/auth/"+path, bytes.NewReader(b))
	r.Header.Set("X-Request-ID", newID("req_"))
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	var out map[string]any
	if e = json.Unmarshal(w.Body.Bytes(), &out); e != nil {
		t.Fatal(w.Code, w.Body.String())
	}
	return w.Code, out
}
func TestGoogleHTTPJourney(t *testing.T) {
	s, _, h := googleTestService(t)
	status, out := googleRequest(t, h, "google/begin", googleTestAttempt(), "")
	if status != 200 {
		t.Fatal(status, out)
	}
	payload := map[string]any{"attempt_token": out["attempt_token"], "code": "code", "verifier": googleTestVerifier, "nickname": "小满"}
	status, out = googleRequest(t, h, "google/complete", payload, "")
	if status != 200 || out["access_token"] == nil {
		t.Fatal(status, out)
	}
	if _, e := s.AuthAccess(out["access_token"].(string)); e != nil {
		t.Fatal(e)
	}
	status, out = googleRequest(t, h, "google/complete", payload, "")
	if status == 200 {
		t.Fatal("replay", out)
	}
	var n int
	s.db.QueryRow("SELECT count(*) FROM accounts").Scan(&n)
	if n != 1 {
		t.Fatal(n)
	}
	in := googleTestAttempt()
	in.DeviceID = "device-two"
	_, out = googleRequest(t, h, "google/begin", in, "")
	_, out = googleRequest(t, h, "google/complete", map[string]any{"attempt_token": out["attempt_token"], "code": "code", "verifier": googleTestVerifier}, "")
	if out["status"] != "takeover_required" {
		t.Fatal(out)
	}
	p, _ := s.Profile(out["account_id"].(string))
	if p.ActiveDevice != "device-one" {
		t.Fatal("took over without confirmation")
	}
	status, out = googleRequest(t, h, "google/takeover", map[string]any{"ticket": out["ticket"], "device_id": "device-two"}, "")
	if status != 200 || out["access_token"] == nil {
		t.Fatal(status, out)
	}
}
func TestGoogleHTTPMigration(t *testing.T) {
	s, a, h := googleTestService(t)
	old := registerTestUser(t, s, "invite", "alice", "mac-a")
	_, out := googleRequest(t, h, "migration/prove", map[string]any{"username": "alice", "password": "correct horse battery staple", "device_id": "mac-a"}, "")
	in := googleTestAttempt()
	body := map[string]any{"device_id": "mac-a", "mode": "link", "challenge": in.Challenge, "redirect_uri": in.RedirectURI, "migration_ticket": out["ticket"]}
	status, out := googleRequest(t, h, "google/begin", body, "")
	if status != 200 {
		t.Fatal(status, out)
	}
	status, out = googleRequest(t, h, "google/complete", map[string]any{"attempt_token": out["attempt_token"], "code": "code", "verifier": googleTestVerifier}, "")
	if status != 200 || out["status"] != "link_confirmation" {
		t.Fatal(status, out)
	}
	var n int
	s.db.QueryRow("SELECT count(*) FROM google_identities").Scan(&n)
	if n != 0 {
		t.Fatal("bound before confirmation")
	}
	status, out = googleRequest(t, h, "google/link-confirm", map[string]any{"ticket": out["ticket"], "device_id": "mac-a"}, "")
	if status != 200 || out["account_id"] != old.AccountID {
		t.Fatal(status, out)
	}
	a.MigrationOpen = false
	status, out = googleRequest(t, h, "migration/prove", map[string]any{}, "")
	if status == 200 || out["code"] != "MIGRATION_CLOSED" {
		t.Fatal(status, out)
	}
}
func TestGoogleLegacyFence(t *testing.T) {
	s, _, h := googleTestService(t)
	old := registerTestUser(t, s, "invite", "alice", "mac-a")
	for _, path := range []string{"register", "login", "recover", "claim", "takeover"} {
		status, _ := googleRequest(t, h, path, map[string]any{}, "")
		if status != 426 {
			t.Fatal(path, status)
		}
	}
	if _, e := s.AuthAccess(old.AccessToken); e == nil {
		t.Fatal("legacy business access")
	}
	if _, e := s.Refresh(old.RefreshToken); e == nil {
		t.Fatal("legacy refresh access")
	}
	if _, e := s.AuthMigrationAccess(old.AccessToken); e != nil {
		t.Fatal("migration identity lost")
	}
}
func TestGoogleHTTPFailClosed(t *testing.T) {
	_, _, h := googleTestService(t)
	for _, raw := range []string{`{}`, `{"device_id":"a","device_id":"b"}`, `{"unknown":1}`, `{} {}`} {
		r := httptest.NewRequest("POST", "http://petlink.test/v2/auth/google/begin", bytes.NewBufferString(raw))
		r.Header.Set("X-Request-ID", "one")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code == 200 {
			t.Fatal("invalid input accepted", raw)
		}
	}
	r := httptest.NewRequest("POST", "http://petlink.test/v2/auth/google/begin", bytes.NewBufferString(`{}`))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code == 200 {
		t.Fatal("no ID accepted")
	}
}
func TestGoogleProxyHeaders(t *testing.T) {
	r := httptest.NewRequest("GET", "http://petlink.test", nil)
	r.RemoteAddr = "192.0.2.1:3456"
	r.Header.Set("X-Forwarded-For", "198.51.100.1")
	if googleClientIP(r) != "192.0.2.1" {
		t.Fatal("trusted spoofed header")
	}
}
