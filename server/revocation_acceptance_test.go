package main

import (
	"net/http/httptest"
	"testing"
)

// Exercise the authenticated HTTP mutation rather than only the store helper.
func TestRevocationHTTPReaddAndRestart(t *testing.T) {
	for _, action := range []string{"remove", "block"} {
		t.Run(action, func(t *testing.T) {
			s, rt, owner, requester, _, envelope := connectAvatarFixture(t)
			ts := httptest.NewServer(SocialHandlerWithRuntime(s, rt))
			defer ts.Close()
			post := func(path, token, id string, body any, want int) {
				t.Helper()
				resp, _ := avatarAPI(t, ts.Client(), "POST", ts.URL+path, token, id, body)
				if resp.StatusCode != want {
					t.Fatalf("%s: status %d want %d", path, resp.StatusCode, want)
				}
			}
			post("/v3/avatar/tasks", requester.AccessToken, "submit", map[string]any{"owner_id": owner.AccountID, "envelope": envelope}, 201)
			post("/v3/avatar/tasks/"+envelope.TaskID+"/respond", owner.AccessToken, "approve", map[string]any{"accept": true}, 200)
			post("/v2/friends/"+action, requester.AccessToken, "revoke", map[string]any{"account_id": owner.AccountID}, 200)
			for _, token := range []string{owner.AccessToken, requester.AccessToken} {
				resp, body := avatarAPI(t, ts.Client(), "GET", ts.URL+"/v3/avatar/tasks/"+envelope.TaskID, token, "", nil)
				if resp.StatusCode != 200 || body["state"] != "revoked" || body["error_code"] != "AVATAR_TASK_REVOKED" {
					t.Fatalf("participant cannot observe revocation: status %d state %v", resp.StatusCode, body["state"])
				}
			}
			for _, who := range []struct{ account, device, session string }{{owner.AccountID, "owner-device", "owner-session"}, {requester.AccountID, "requester-device", "requester-session"}} {
				snap, err := rt.Snapshot(who.account, who.device, who.session, "verify")
				if err != nil {
					t.Fatal(err)
				}
				found := false
				for _, view := range snap.AvatarTasks {
					if view.Task.ID == envelope.TaskID {
						found = true
						if view.Task.State != AvatarRevoked || view.Request != nil || view.Result != nil {
							t.Fatal("unsafe revoked projection")
						}
					}
				}
				if !found {
					t.Fatal("missing revoked status")
				}
			}
			if action == "remove" {
				makeFriends(t, s, owner, requester)
			}
			resp, _ := avatarAPI(t, ts.Client(), "POST", ts.URL+"/v3/avatar/tasks/"+envelope.TaskID+"/start", owner.AccessToken, "late-start", map[string]any{})
			if resp.StatusCode < 400 || resp.StatusCode >= 500 {
				t.Fatalf("late start status %d", resp.StatusCode)
			}
			// Reopen the real test database to exercise startup reconciliation.
			var seq int
			var name, path string
			if err := s.db.QueryRow("PRAGMA database_list").Scan(&seq, &name, &path); err != nil {
				t.Fatal(err)
			}
			ts.Close()
			if err := s.Close(); err != nil {
				t.Fatal(err)
			}
			reopened, err := OpenSocialStore(path)
			if err != nil {
				t.Fatal(err)
			}
			defer reopened.Close()
			task, err := reopened.AvatarTask(envelope.TaskID)
			if err != nil || task.State != AvatarRevoked || task.ErrorCode != "AVATAR_TASK_REVOKED" {
				t.Fatalf("revocation lost after restart: %s %v", task.State, err)
			}
			if reopened.StartAvatarTask(owner.AccountID, envelope.TaskID) == nil {
				t.Fatal("old task revived after restart")
			}
		})
	}
}
