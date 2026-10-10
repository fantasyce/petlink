package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func apiJSON(t *testing.T, client *http.Client, method, url, token string, body any) (*http.Response, map[string]any) {
	t.Helper()
	var data []byte
	if body != nil {
		data, _ = json.Marshal(body)
	}
	req, _ := http.NewRequest(method, url, bytes.NewReader(data))
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if method != "GET" {
		req.Header.Set("X-Request-ID", newID("test_"))
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	return resp, out
}

func TestV2RegisterAndAuthenticatedMe(t *testing.T) {
	s := newTestSocial(t)
	_ = s.CreateInvite("http-invite", time.Now().Add(time.Hour))
	ts := httptest.NewServer(SocialHandler(s))
	defer ts.Close()
	resp, out := apiJSON(t, ts.Client(), "POST", ts.URL+"/v2/auth/register", "", map[string]any{"request_id": "register-1", "invite": "http-invite", "username": "alice", "password": "correct horse battery staple", "nickname": "Alice", "device_id": "mac-a"})
	if resp.StatusCode != 201 {
		t.Fatalf("register status=%d body=%v", resp.StatusCode, out)
	}
	token, _ := out["access_token"].(string)
	if token == "" {
		t.Fatalf("missing token: %v", out)
	}
	resp, out = apiJSON(t, ts.Client(), "GET", ts.URL+"/v2/me", token, nil)
	if resp.StatusCode != 200 || out["username"] != "alice" {
		t.Fatalf("me status=%d body=%v", resp.StatusCode, out)
	}
	resp, out = apiJSON(t, ts.Client(), "GET", ts.URL+"/v2/me", "bad-token", nil)
	if resp.StatusCode != 401 || out["code"] != "UNAUTHORIZED" {
		t.Fatalf("unauthorized status=%d body=%v", resp.StatusCode, out)
	}
}

func TestV2RejectsMissingRequestID(t *testing.T) {
	s := newTestSocial(t)
	ts := httptest.NewServer(SocialHandler(s))
	defer ts.Close()
	req, _ := http.NewRequest("POST", ts.URL+"/v2/auth/login", bytes.NewBufferString(`{"username":"alice"}`))
	req.Header.Set("Content-Type", "application/json")
	resp, err := ts.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(resp.Body).Decode(&out)
	if resp.StatusCode != 400 || out["code"] != "REQUEST_ID_REQUIRED" {
		t.Fatalf("status=%d body=%v", resp.StatusCode, out)
	}
}

func fixedRequest(t *testing.T, client *http.Client, method, url, token, requestID string, body any) (*http.Response, []byte) {
	t.Helper()
	data, _ := json.Marshal(body)
	req, _ := http.NewRequest(method, url, bytes.NewReader(data))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Request-ID", requestID)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp, out
}

func TestV2IdempotencyReplaysSuccessAndRejectsChangedPayload(t *testing.T) {
	s := newTestSocial(t)
	_ = s.CreateInvite("once-only", time.Now().Add(time.Hour))
	ts := httptest.NewServer(SocialHandler(s))
	defer ts.Close()
	body := map[string]any{"invite": "once-only", "username": "idem", "password": "correct horse battery staple", "nickname": "Idem", "device_id": "mac-a"}
	first, firstBody := fixedRequest(t, ts.Client(), "POST", ts.URL+"/v2/auth/register", "", "same-register", body)
	second, secondBody := fixedRequest(t, ts.Client(), "POST", ts.URL+"/v2/auth/register", "", "same-register", body)
	if first.StatusCode != 201 || second.StatusCode != 201 || !bytes.Equal(firstBody, secondBody) || second.Header.Get("Idempotency-Replayed") != "true" {
		t.Fatalf("first=%d second=%d replay=%q equal=%v", first.StatusCode, second.StatusCode, second.Header.Get("Idempotency-Replayed"), bytes.Equal(firstBody, secondBody))
	}
	var persisted int
	_ = s.db.QueryRow(`SELECT count(*) FROM idempotency`).Scan(&persisted)
	if persisted != 0 {
		t.Fatalf("authentication response persisted in idempotency table: %d", persisted)
	}
	body["nickname"] = "Changed"
	conflict, _ := fixedRequest(t, ts.Client(), "POST", ts.URL+"/v2/auth/register", "", "same-register", body)
	if conflict.StatusCode != 409 {
		t.Fatalf("changed payload status=%d", conflict.StatusCode)
	}
}

func TestV2ContactPolicyUsesClientWireFields(t *testing.T) {
	s := newTestSocial(t)
	owner := registerTestUser(t, s, "wire-owner", "wireowner", "wire-mac-a")
	peer := registerTestUser(t, s, "wire-peer", "wirepeer", "wire-mac-b")
	makeFriends(t, s, owner, peer)
	ts := httptest.NewServer(SocialHandler(s))
	defer ts.Close()
	for _, enabled := range []bool{true, false} {
		resp, _ := apiJSON(t, ts.Client(), "PATCH", ts.URL+"/v2/contacts/"+peer.AccountID+"/policy", owner.AccessToken, map[string]any{"trusted": true, "share_agent": enabled, "note": "测试备注"})
		if resp.StatusCode != 200 {
			t.Fatalf("policy status=%d", resp.StatusCode)
		}
		contacts, err := s.Contacts(owner.AccountID)
		if err != nil || len(contacts) != 1 {
			t.Fatalf("contacts: %v", err)
		}
		if contacts[0].ShareAgent != enabled || !contacts[0].Trusted || contacts[0].Note != "测试备注" {
			t.Fatalf("wire policy not persisted: %+v", contacts[0])
		}
	}
}
