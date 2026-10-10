package main

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

// Fails if refresh stops revoking its predecessor or logout leaves refresh usable.
func TestGoogleAcceptanceRefreshRotationLogout(t *testing.T) {
	s, a, h := googleTestService(t)
	id, _, err := s.ResolveGoogle(GoogleIdentity{"https://accounts.google.com", "rotation", "fixture@example.invalid"}, "Fixture")
	if err != nil {
		t.Fatal(err)
	}
	first, err := a.Runtime.IssueGoogleSession(id, "rotation-device", false)
	if err != nil {
		t.Fatal(err)
	}
	status, out := googleRequest(t, h, "refresh", map[string]any{"refresh_token": first.RefreshToken}, "")
	if status != 200 {
		t.Fatal("refresh status", status)
	}
	access, ok := out["access_token"].(string)
	if !ok {
		t.Fatal("missing access")
	}
	refresh, ok := out["refresh_token"].(string)
	if !ok {
		t.Fatal("missing refresh")
	}
	if _, err = s.AuthAccess(first.AccessToken); err == nil {
		t.Fatal("predecessor still active")
	}
	status, _ = googleRequest(t, h, "refresh", map[string]any{"refresh_token": first.RefreshToken}, "")
	if status == 200 {
		t.Fatal("refresh replay accepted")
	}
	status, _ = googleRequest(t, h, "logout", map[string]any{}, access)
	if status != 200 {
		t.Fatal("logout status", status)
	}
	status, _ = googleRequest(t, h, "refresh", map[string]any{"refresh_token": refresh}, "")
	if status == 200 {
		t.Fatal("logout left refresh usable")
	}
}

// Fails if cached WebSocket replies bypass Google session revocation checks.
func TestGoogleAcceptanceSocketRevocationAndProjection(t *testing.T) {
	for _, operation := range []string{"logout", "takeover", "refresh"} {
		t.Run(operation, func(t *testing.T) {
			s, a, h := googleTestService(t)
			identity := GoogleIdentity{"https://accounts.google.com", "socket-fixture-subject", "private-fixture@example.invalid"}
			id, _, err := s.ResolveGoogle(identity, "Fixture")
			if err != nil {
				t.Fatal(err)
			}
			first, err := a.Runtime.IssueGoogleSession(id, "socket-device", false)
			if err != nil {
				t.Fatal(err)
			}
			a.Runtime.readyAt = time.Now()
			ts := httptest.NewServer(h)
			defer ts.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			c, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/v2/ws", nil)
			if err != nil {
				t.Fatal(err)
			}
			defer c.CloseNow()
			if err = wsjson.Write(ctx, c, V2Auth{AccessToken: first.AccessToken, DeviceID: "socket-device", Protocol: 2}); err != nil {
				t.Fatal(err)
			}
			command := V2Command{RequestID: "cached-sync", Action: "sync"}
			if err = wsjson.Write(ctx, c, command); err != nil {
				t.Fatal(err)
			}
			var snap V2Snapshot
			if err = wsjson.Read(ctx, c, &snap); err != nil {
				t.Fatal(err)
			}
			if len(snap.Pets) != 1 {
				t.Fatal("missing initial display")
			}
			payload, _ := json.Marshal(snap)
			for _, secret := range []string{identity.Email, identity.Subject, first.AccessToken, first.RefreshToken} {
				if strings.Contains(string(payload), secret) {
					t.Fatal("private identity leaked in snapshot")
				}
			}
			switch operation {
			case "logout":
				err = s.Logout(first.AccessToken)
			case "takeover":
				_, err = a.Runtime.IssueGoogleSession(id, "next-device", true)
			case "refresh":
				_, err = s.Refresh(first.RefreshToken)
			}
			if err != nil {
				t.Fatal(err)
			}
			_ = wsjson.Write(ctx, c, command)
			if err = wsjson.Read(ctx, c, &snap); err == nil {
				t.Fatal("revoked socket returned cached display lease")
			}
		})
	}
}
