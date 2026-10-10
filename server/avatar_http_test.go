package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func avatarAPI(t *testing.T, client *http.Client, method, url, token, requestID string, body any) (*http.Response, map[string]any) {
	t.Helper()
	data, _ := json.Marshal(body)
	req, _ := http.NewRequest(method, url, strings.NewReader(string(data)))
	req.Header.Set("Content-Type", "application/json")
	if requestID != "" {
		req.Header.Set("X-Request-ID", requestID)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
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

func TestAvatarHTTPPolicyCapabilitiesAndTaskLifecycle(t *testing.T) {
	s, rt, owner, requester, _, envelope := connectAvatarFixture(t)
	ts := httptest.NewServer(SocialHandlerWithRuntime(s, rt))
	defer ts.Close()

	resp, out := avatarAPI(t, ts.Client(), "GET", ts.URL+"/v3/avatar/capabilities", owner.AccessToken, "", nil)
	if resp.StatusCode != 200 || out["protocol"] != float64(3) || out["key_registered"] != true {
		t.Fatalf("capabilities status=%d body=%v", resp.StatusCode, out)
	}
	resp, out = avatarAPI(t, ts.Client(), "GET", ts.URL+"/v3/avatar/contacts/"+owner.AccountID+"/capability", requester.AccessToken, "", nil)
	if resp.StatusCode != 200 || out["owner_id"] != owner.AccountID || out["device_id"] == "" || out["agreement_public_key"] == "" || out["visit_revision"] == float64(0) {
		t.Fatalf("contact capability status=%d body=%v", resp.StatusCode, out)
	}
	resp, out = avatarAPI(t, ts.Client(), "PATCH", ts.URL+"/v3/contacts/"+requester.AccountID+"/avatar-policy", owner.AccessToken, "policy-1", map[string]any{"allow_auto_ask": true, "provider": "claude"})
	if resp.StatusCode != 200 || out["allow_auto_ask"] != true || out["provider"] != "claude" || out["policy_revision"] != float64(1) {
		t.Fatalf("policy status=%d body=%v", resp.StatusCode, out)
	}
	envelope.PolicyRevision = 1
	// Signature no longer matches after policy revision changes.
	resp, out = avatarAPI(t, ts.Client(), "POST", ts.URL+"/v3/avatar/tasks", requester.AccessToken, "task-invalid", map[string]any{"owner_id": owner.AccountID, "envelope": envelope})
	if resp.StatusCode != 400 || out["code"] != "AVATAR_PROTOCOL_ERROR" {
		t.Fatalf("unsigned mutation status=%d body=%v", resp.StatusCode, out)
	}
}

func TestAvatarHTTPRejectsMissingRequestIDAndHidesCiphertextFromTaskRead(t *testing.T) {
	s, rt, owner, requester, _, envelope := connectAvatarFixture(t)
	ts := httptest.NewServer(SocialHandlerWithRuntime(s, rt))
	defer ts.Close()

	resp, out := avatarAPI(t, ts.Client(), "POST", ts.URL+"/v3/avatar/tasks", requester.AccessToken, "", map[string]any{"owner_id": owner.AccountID, "envelope": envelope})
	if resp.StatusCode != 400 || out["code"] != "REQUEST_ID_REQUIRED" {
		t.Fatalf("missing request id status=%d body=%v", resp.StatusCode, out)
	}
	resp, out = avatarAPI(t, ts.Client(), "POST", ts.URL+"/v3/avatar/tasks", requester.AccessToken, "task-1", map[string]any{"owner_id": owner.AccountID, "envelope": envelope})
	if resp.StatusCode != 201 {
		t.Fatalf("create status=%d body=%v", resp.StatusCode, out)
	}
	taskID, _ := out["id"].(string)
	resp, out = avatarAPI(t, ts.Client(), "GET", ts.URL+"/v3/avatar/tasks/"+taskID, owner.AccessToken, "", nil)
	if resp.StatusCode != 200 || out["request_digest"] == "" {
		t.Fatalf("read status=%d body=%v", resp.StatusCode, out)
	}
	encoded, _ := json.Marshal(out)
	if strings.Contains(string(encoded), envelope.Ciphertext) || strings.Contains(string(encoded), "encrypted-question") {
		t.Fatalf("task read leaked ciphertext: %s", encoded)
	}
}
