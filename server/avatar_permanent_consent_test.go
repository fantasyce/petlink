package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestAvatarPermanentApprovalAnswersCurrentAndFutureQuestions(t *testing.T) {
	s, rt, owner, requester, key, envelope := connectAvatarFixture(t)
	task, err := rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, envelope)
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(SocialHandlerWithRuntime(s, rt))
	defer ts.Close()
	resp, out := avatarAPI(t, ts.Client(), "POST", ts.URL+"/v3/avatar/tasks/"+task.ID+"/respond", owner.AccessToken, "remember-current", map[string]any{"accept": true, "remember": true})
	policy, err := s.AvatarPolicy(owner.AccountID, requester.AccountID)
	if resp.StatusCode != 200 || err != nil || !policy.AllowAutoAsk || policy.Revision != 1 || out["auto_ask_granted"] != true {
		t.Fatalf("permanent approval not persisted: status=%d policy=%+v err=%v", resp.StatusCode, policy, err)
	}
	current, _ := s.AvatarTask(task.ID)
	if current.State != AvatarRouted || current.PolicyRevision != 0 {
		t.Fatalf("current signed request must remain approved under its original revision: %+v", current)
	}
	snapshot, err := rt.Snapshot(owner.AccountID, "owner-device", "owner-session", "approved")
	if err != nil || len(snapshot.AvatarTasks) != 1 || snapshot.AvatarTasks[0].Request == nil || snapshot.AvatarTasks[0].Request.Signature != envelope.Signature {
		t.Fatal("approval lost or rewrote the encrypted request")
	}
	if err = rt.StartAvatar(owner.AccountID, task.ID); err != nil {
		t.Fatal(err)
	}
	if err = s.CompleteAvatarTask(owner.AccountID, task.ID, strings.Repeat("a", 64)); err != nil {
		t.Fatal(err)
	}
	other, _ := s.AvatarPolicy(requester.AccountID, owner.AccountID)
	if other.AllowAutoAsk {
		t.Fatal("grant leaked into reverse direction")
	}
	envelope.TaskID = newID("dlg_")
	envelope.Sequence++
	envelope.PolicyRevision = 1
	envelope.Signature = base64.RawURLEncoding.EncodeToString(ed25519.Sign(key, envelope.SignableBytes()))
	next, err := rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, envelope)
	if err != nil || next.State != AvatarRouted {
		t.Fatalf("next question did not bypass approval: %s %v", next.State, err)
	}
	if _, err = s.SetAvatarPolicy(owner.AccountID, requester.AccountID, AvatarPolicy{Provider: "owner_default"}); err != nil {
		t.Fatal(err)
	}
	revoked, _ := s.AvatarTask(next.ID)
	if revoked.State != AvatarRevoked {
		t.Fatal("withdrawal failed to stop in-flight automatic answer")
	}
	envelope.TaskID = newID("dlg_")
	envelope.Sequence++
	envelope.PolicyRevision = 2
	envelope.Signature = base64.RawURLEncoding.EncodeToString(ed25519.Sign(key, envelope.SignableBytes()))
	next, err = rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, envelope)
	if err != nil || next.State != AvatarPendingApproval {
		t.Fatalf("withdrawal failed to restore approval: %s %v", next.State, err)
	}
}

func TestAvatarPermanentApprovalCannotGrantForInvalidQuestion(t *testing.T) {
	for _, kind := range []string{"wrong-owner", "expired", "cancelled", "reject-and-remember"} {
		t.Run(kind, func(t *testing.T) {
			s, rt, owner, requester, _, envelope := connectAvatarFixture(t)
			task, err := rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, envelope)
			if err != nil {
				t.Fatal(err)
			}
			token := owner.AccessToken
			accept := true
			switch kind {
			case "wrong-owner":
				token = requester.AccessToken
			case "expired":
				_, err = s.db.Exec(`UPDATE avatar_tasks SET expires_at=? WHERE id=?`, time.Now().Add(-time.Second).UnixMilli(), task.ID)
			case "cancelled":
				err = rt.CancelAvatar(requester.AccountID, task.ID)
			case "reject-and-remember":
				accept = false
			}
			if err != nil {
				t.Fatal(err)
			}
			ts := httptest.NewServer(SocialHandlerWithRuntime(s, rt))
			defer ts.Close()
			resp, _ := avatarAPI(t, ts.Client(), "POST", ts.URL+"/v3/avatar/tasks/"+task.ID+"/respond", token, "invalid-grant", map[string]any{"accept": accept, "remember": true})
			policy, _ := s.AvatarPolicy(owner.AccountID, requester.AccountID)
			if resp.StatusCode == 200 || policy.AllowAutoAsk || policy.Revision != 0 {
				t.Fatalf("invalid approval granted permanent permission: status=%d policy=%+v", resp.StatusCode, policy)
			}
		})
	}
}

func TestAvatarPermanentApprovalRollsBackOnStorageFailure(t *testing.T) {
	s, rt, owner, requester, _, envelope := connectAvatarFixture(t)
	task, err := rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, envelope)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.db.Exec(`CREATE TRIGGER reject_permanent_grant BEFORE INSERT ON avatar_policies BEGIN SELECT RAISE(ABORT,'consent storage failure'); END`); err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(SocialHandlerWithRuntime(s, rt))
	defer ts.Close()
	resp, _ := avatarAPI(t, ts.Client(), "POST", ts.URL+"/v3/avatar/tasks/"+task.ID+"/respond", owner.AccessToken, "grant-storage-failure", map[string]any{"accept": true, "remember": true})
	policy, _ := s.AvatarPolicy(owner.AccountID, requester.AccountID)
	current, _ := s.AvatarTask(task.ID)
	if resp.StatusCode == 200 || policy.AllowAutoAsk || current.State != AvatarPendingApproval {
		t.Fatalf("partial consent committed: status=%d policy=%+v task=%s", resp.StatusCode, policy, current.State)
	}
}

func TestAvatarPermanentApprovalPreservesProviderAndContactScope(t *testing.T) {
	for _, provider := range []string{"claude", "codex", "deepseek", "owner_default"} {
		t.Run(provider, func(t *testing.T) {
			s, rt, owner, requester, key, envelope := connectAvatarFixture(t)
			if _, err := s.SetAvatarPolicy(owner.AccountID, requester.AccountID, AvatarPolicy{Provider: provider}); err != nil {
				t.Fatal(err)
			}
			envelope.PolicyRevision = 1
			envelope.Signature = base64.RawURLEncoding.EncodeToString(ed25519.Sign(key, envelope.SignableBytes()))
			task, err := rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, envelope)
			if err != nil {
				t.Fatal(err)
			}
			other := registerTestUser(t, s, "consent-other", "consentother", "other-device")
			makeFriends(t, s, owner, other)
			ts := httptest.NewServer(SocialHandlerWithRuntime(s, rt))
			defer ts.Close()
			resp, _ := avatarAPI(t, ts.Client(), "POST", ts.URL+"/v3/avatar/tasks/"+task.ID+"/respond", owner.AccessToken, "grant-provider", map[string]any{"accept": true, "remember": true})
			policy, _ := s.AvatarPolicy(owner.AccountID, requester.AccountID)
			otherPolicy, _ := s.AvatarPolicy(owner.AccountID, other.AccountID)
			current, _ := s.AvatarTask(task.ID)
			if resp.StatusCode != 200 || !policy.AllowAutoAsk || policy.Provider != provider || policy.Revision != 2 || current.Provider != provider || current.PolicyRevision != 1 || otherPolicy.AllowAutoAsk {
				t.Fatalf("grant changed provider or leaked into another contact: status=%d policy=%+v other=%+v task=%+v", resp.StatusCode, policy, otherPolicy, current)
			}
		})
	}
}
