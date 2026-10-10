package main

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

func TestWebSocketCredentialRenewalPreservesVisit(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "ia", "alice", "mac-a")
	b := registerTestUser(t, s, "ib", "bob", "mac-b")
	makeFriends(t, s, a, b)
	if e := s.SetContactPolicy(b.AccountID, a.AccountID, ContactPolicy{Trusted: true}); e != nil {
		t.Fatal(e)
	}
	if _, e := s.db.Exec(`UPDATE accounts SET auth_method='google'`); e != nil {
		t.Fatal(e)
	}
	s.googleOnly.Store(true)
	rt := NewSocialRuntime(s)
	rt.readyAt = time.Now()
	ts := httptest.NewServer(SocialHandlerWithRuntime(s, rt))
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	dial := func(auth AuthResult, device string) *websocket.Conn {
		t.Helper()
		c, _, e := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/v2/ws", nil)
		if e != nil {
			t.Fatal(e)
		}
		t.Cleanup(func() { c.CloseNow() })
		if e = wsjson.Write(ctx, c, map[string]any{"access_token": auth.AccessToken, "device_id": device, "protocol": 2, "supports_credential_refresh": true}); e != nil {
			t.Fatal(e)
		}
		return c
	}
	guest, host := dial(a, "mac-a"), dial(b, "mac-b")
	ask := func(c *websocket.Conn, cmd V2Command) V2Snapshot {
		t.Helper()
		if e := wsjson.Write(ctx, c, cmd); e != nil {
			t.Fatal(e)
		}
		var snap V2Snapshot
		if e := wsjson.Read(ctx, c, &snap); e != nil {
			t.Fatal(e)
		}
		if snap.Error != "" {
			t.Fatalf("unexpected command error: %s", snap.Error)
		}
		return snap
	}
	ask(guest, V2Command{Action: "sync", RequestID: "guest-initial"})
	ask(host, V2Command{Action: "sync", RequestID: "host-initial"})
	snap := ask(guest, V2Command{Action: "visit_request", PeerID: b.AccountID, RequestID: "visit"})
	for _, hide := range snap.Hides {
		ask(guest, V2Command{Action: "ack", PetID: hide.PetID, Revision: hide.Revision, RequestID: "hide-ack"})
	}
	if snap = ask(host, V2Command{Action: "sync", RequestID: "host-arrival"}); len(snap.Pets) != 2 {
		t.Fatal("host did not receive guest before renewal")
	}
	if _, e := s.db.Exec(`UPDATE sessions SET access_expires=? WHERE access_hash=?`, time.Now().Add(-time.Second).UnixMilli(), hashValue(a.AccessToken)); e != nil {
		t.Fatal(e)
	}
	if e := wsjson.Write(ctx, guest, V2Command{Action: "wave", RequestID: "expired-wave"}); e != nil {
		t.Fatal(e)
	}
	var control map[string]any
	if e := wsjson.Read(ctx, guest, &control); e != nil {
		t.Fatalf("credential expiry closed the live visit instead of requesting renewal: %v", e)
	}
	if control["type"] != "auth_refresh_required" || control["own"] != nil || control["pets"] != nil {
		t.Fatal("expired credentials received protected data instead of a renewal control")
	}
	var wave int64
	if e := s.db.QueryRow(`SELECT wave_seq FROM pets WHERE owner_id=?`, a.AccountID).Scan(&wave); e != nil {
		t.Fatal(e)
	}
	if wave != 0 {
		t.Fatal("expired credentials executed a mutation")
	}
	renewed, e := s.Refresh(a.RefreshToken)
	if e != nil {
		t.Fatal(e)
	}
	if e = wsjson.Write(ctx, guest, map[string]any{"action": "reauth", "request_id": "renewed", "access_token": renewed.AccessToken}); e != nil {
		t.Fatal(e)
	}
	if e = wsjson.Read(ctx, guest, &snap); e != nil {
		t.Fatalf("same-identity renewal failed: %v", e)
	}
	if snap.Own.Phase != "visit" || snap.Own.LocationID != b.AccountID {
		t.Fatal("renewal recalled the visitor")
	}
	if snap = ask(host, V2Command{Action: "sync", RequestID: "host-renewed"}); len(snap.Pets) != 2 {
		t.Fatal("host lost its visitor after renewal")
	}
	// Real transport loss remains a recall; renewal does not relax that policy.
	guest.CloseNow()
	for i := 0; i < 50; i++ {
		var status string
		if e = s.db.QueryRow(`SELECT status FROM visit_requests WHERE guest_id=?`, a.AccountID).Scan(&status); e != nil {
			t.Fatal(e)
		}
		if status == "completed" {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("real disconnect did not end the visit")
}

func TestAckHideDuplicateDoesNotReportVisitExpired(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "ia", "alice", "mac-a")
	b := registerTestUser(t, s, "ib", "bob", "mac-b")
	makeFriends(t, s, a, b)
	if e := s.SetContactPolicy(b.AccountID, a.AccountID, ContactPolicy{Trusted: true}); e != nil {
		t.Fatal(e)
	}
	rt := NewSocialRuntime(s)
	rt.readyAt = time.Now()
	if e := rt.Connect(a.AccountID, "mac-a", "ws-a"); e != nil {
		t.Fatal(e)
	}
	if e := rt.Connect(b.AccountID, "mac-b", "ws-b"); e != nil {
		t.Fatal(e)
	}
	if _, e := rt.Snapshot(a.AccountID, "mac-a", "ws-a", "initial"); e != nil {
		t.Fatal(e)
	}
	if _, e := rt.RequestVisit(a.AccountID, b.AccountID); e != nil {
		t.Fatal(e)
	}
	snap, e := rt.Snapshot(a.AccountID, "mac-a", "ws-a", "travel")
	if e != nil || len(snap.Hides) != 1 {
		t.Fatal("missing transfer hide")
	}
	hide := snap.Hides[0]
	if e = rt.AckHide(a.AccountID, "mac-a", "ws-a", hide.PetID, hide.Revision); e != nil {
		t.Fatal(e)
	}
	if _, e = rt.Snapshot(b.AccountID, "mac-b", "ws-b", "arrival"); e != nil {
		t.Fatal(e)
	}
	if e = rt.AckHide(a.AccountID, "mac-a", "ws-a", hide.PetID, hide.Revision); e != nil {
		t.Fatalf("duplicate hide acknowledgement became a false visit-expired error: %v", e)
	}
	if e = rt.AckHide(b.AccountID, "mac-b", "ws-b", hide.PetID, hide.Revision); e == nil {
		t.Fatal("another session replayed the owner's acknowledgement")
	}
	if e = rt.AckHide(a.AccountID, "mac-a", "ws-a", hide.PetID, hide.Revision+1); e == nil {
		t.Fatal("future revision acknowledgement accepted")
	}
	if e = rt.Recall(a.AccountID); e != nil {
		t.Fatal(e)
	}
	returning, e := rt.Snapshot(b.AccountID, "mac-b", "ws-b", "returning")
	if e != nil || len(returning.Hides) != 1 {
		t.Fatal("missing return hide")
	}
	if e = rt.AckHide(b.AccountID, "mac-b", "ws-b", returning.Hides[0].PetID, returning.Hides[0].Revision); e != nil {
		t.Fatal(e)
	}
	if e = rt.AckHide(a.AccountID, "mac-a", "ws-a", hide.PetID, hide.Revision); e != nil {
		t.Fatalf("returning erased the earlier successful acknowledgement: %v", e)
	}
}

func TestSocketRenewalCannotSwitchIdentityOrUseRevokedToken(t *testing.T) {
	for _, scenario := range []string{"other-account", "replaced-device", "revoked-token"} {
		t.Run(scenario, func(t *testing.T) {
			s := newTestSocial(t)
			a := registerTestUser(t, s, "ia", "alice", "mac-a")
			b := registerTestUser(t, s, "ib", "bob", "mac-b")
			if _, e := s.db.Exec(`UPDATE accounts SET auth_method='google'`); e != nil {
				t.Fatal(e)
			}
			s.googleOnly.Store(true)
			ts := httptest.NewServer(SocialHandlerWithRuntime(s, NewSocialRuntime(s)))
			defer ts.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			c, _, e := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/v2/ws", nil)
			if e != nil {
				t.Fatal(e)
			}
			defer c.CloseNow()
			if e = wsjson.Write(ctx, c, map[string]any{"access_token": a.AccessToken, "device_id": "mac-a", "protocol": 2, "supports_credential_refresh": true}); e != nil {
				t.Fatal(e)
			}
			if e = wsjson.Write(ctx, c, map[string]string{"action": "reauth", "request_id": "valid", "access_token": a.AccessToken}); e != nil {
				t.Fatal(e)
			}
			var snap V2Snapshot
			if e = wsjson.Read(ctx, c, &snap); e != nil || snap.SelfID != a.AccountID || snap.Error != "" {
				t.Fatal("initial same-identity reauthorization failed")
			}
			token := a.AccessToken
			switch scenario {
			case "other-account":
				token = b.AccessToken
			case "replaced-device":
				if _, e = s.db.Exec(`UPDATE accounts SET active_device='mac-other' WHERE id=?`, a.AccountID); e != nil {
					t.Fatal(e)
				}
			case "revoked-token":
				if e = s.Logout(a.AccessToken); e != nil {
					t.Fatal(e)
				}
			}
			if e = wsjson.Write(ctx, c, map[string]string{"action": "reauth", "request_id": "invalid", "access_token": token}); e != nil {
				t.Fatal(e)
			}
			var response map[string]any
			if e = wsjson.Read(ctx, c, &response); e == nil {
				t.Fatal("invalid reauthorization received a response instead of closing")
			}
		})
	}
}

func TestExpiredSocketCannotKeepRenewalWindowAliveWithHeartbeats(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "ia", "alice", "mac-a")
	if _, e := s.db.Exec(`UPDATE accounts SET auth_method='google'`); e != nil {
		t.Fatal(e)
	}
	s.googleOnly.Store(true)
	ts := httptest.NewServer(SocialHandlerWithRuntime(s, NewSocialRuntime(s)))
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	c, _, e := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/v2/ws", nil)
	if e != nil {
		t.Fatal(e)
	}
	defer c.CloseNow()
	if e = wsjson.Write(ctx, c, map[string]any{"access_token": a.AccessToken, "device_id": "mac-a", "protocol": 2, "supports_credential_refresh": true}); e != nil {
		t.Fatal(e)
	}
	if e = wsjson.Write(ctx, c, V2Command{Action: "sync", RequestID: "initial"}); e != nil {
		t.Fatal(e)
	}
	var response map[string]any
	if e = wsjson.Read(ctx, c, &response); e != nil {
		t.Fatal(e)
	}
	if _, e = s.db.Exec(`UPDATE sessions SET access_expires=? WHERE account_id=?`, time.Now().Add(-time.Second).UnixMilli(), a.AccountID); e != nil {
		t.Fatal(e)
	}
	start := time.Now()
	for i := 0; i < 25; i++ {
		if e = wsjson.Write(ctx, c, V2Command{Action: "sync", RequestID: newID("renewal-test-")}); e != nil {
			break
		}
		response = nil
		if e = wsjson.Read(ctx, c, &response); e != nil {
			break
		}
		if response["type"] != "auth_refresh_required" || response["own"] != nil {
			t.Fatal("expired credentials received protected data")
		}
		time.Sleep(400 * time.Millisecond)
	}
	if e == nil || time.Since(start) > 10*time.Second {
		t.Fatal("heartbeats extended an unauthenticated renewal window")
	}
}
