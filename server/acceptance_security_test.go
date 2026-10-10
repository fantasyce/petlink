package main

import (
	"context"
	"fmt"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

func TestAcceptanceRelationshipRevocationPreventsApprovedAvatarStart(t *testing.T) {
	for _, action := range []string{"block", "remove"} {
		t.Run(action, func(t *testing.T) {
			s, rt, owner, requester, _, envelope := connectAvatarFixture(t)
			task, err := rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, envelope)
			if err != nil {
				t.Fatal(err)
			}
			if err = rt.RespondAvatar(owner.AccountID, task.ID, true); err != nil {
				t.Fatal(err)
			}
			if action == "block" {
				err = s.Block(owner.AccountID, requester.AccountID)
			} else {
				err = s.RemoveFriend(owner.AccountID, requester.AccountID)
			}
			if err != nil {
				t.Fatal(err)
			}
			if err = rt.StartAvatar(owner.AccountID, task.ID); err == nil {
				t.Fatal("approved avatar started after relationship revoked")
			}
		})
	}
}

func TestRelationshipRevocationTerminatesAvatarLifecycle(t *testing.T) {
	for _, action := range []string{"block", "remove"} {
		for _, phase := range []string{"pending", "routed", "running"} {
			for _, byRequester := range []bool{false, true} {
				t.Run(fmt.Sprintf("%s/%s/requester=%v", action, phase, byRequester), func(t *testing.T) {
					s, rt, owner, requester, _, envelope := connectAvatarFixture(t)
					task, err := rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, envelope)
					if err != nil {
						t.Fatal(err)
					}
					if phase != "pending" {
						if err = rt.RespondAvatar(owner.AccountID, task.ID, true); err != nil {
							t.Fatal(err)
						}
					}
					if phase == "running" {
						if err = rt.StartAvatar(owner.AccountID, task.ID); err != nil {
							t.Fatal(err)
						}
					}
					a, b := owner.AccountID, requester.AccountID
					if byRequester {
						a, b = b, a
					}
					if action == "block" {
						err = s.Block(a, b)
					} else {
						err = s.RemoveFriend(a, b)
					}
					if err != nil {
						t.Fatal(err)
					}
					got, err := s.AvatarTask(task.ID)
					if err != nil || got.State != AvatarRevoked || got.ErrorCode != "AVATAR_TASK_REVOKED" {
						t.Fatalf("task not revoked: %s %v", got.State, err)
					}
					if s.RespondAvatarTask(owner.AccountID, task.ID, true) == nil {
						t.Fatal("revoked approval accepted")
					}
					if s.StartAvatarTask(owner.AccountID, task.ID) == nil {
						t.Fatal("revoked start accepted")
					}
					if s.CompleteAvatarTask(owner.AccountID, task.ID, strings.Repeat("a", 64)) == nil {
						t.Fatal("revoked result accepted")
					}
					snap, err := rt.Snapshot(owner.AccountID, "owner-device", "owner-session", "revoked")
					if err != nil {
						t.Fatal(err)
					}
					for _, view := range snap.AvatarTasks {
						if view.Task.ID == task.ID && (view.Request != nil || view.Result != nil) {
							t.Fatal("revoked ciphertext projected")
						}
					}
				})
			}
		}
	}
}

func TestAcceptanceAbruptHostSocketLossReturnsGuest(t *testing.T) {
	s := newTestSocial(t)
	guest := registerTestUser(t, s, "drop-g", "dropguest", "g-device")
	host := registerTestUser(t, s, "drop-h", "drophost", "h-device")
	makeFriends(t, s, guest, host)
	if err := s.SetContactPolicy(host.AccountID, guest.AccountID, ContactPolicy{Trusted: true}); err != nil {
		t.Fatal(err)
	}
	rt := NewSocialRuntime(s)
	rt.readyAt = time.Now()
	if err := rt.Connect(guest.AccountID, "g-device", "guest-session"); err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(SocialHandlerWithRuntime(s, rt))
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/v2/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	if err = wsjson.Write(ctx, conn, V2Auth{AccessToken: host.AccessToken, DeviceID: "h-device", Protocol: 2}); err != nil {
		t.Fatal(err)
	}
	syncHost := func(id string) V2Snapshot {
		t.Helper()
		if err := wsjson.Write(ctx, conn, V2Command{RequestID: id, Action: "sync"}); err != nil {
			t.Fatal(err)
		}
		var snap V2Snapshot
		if err := wsjson.Read(ctx, conn, &snap); err != nil {
			t.Fatal(err)
		}
		return snap
	}
	syncHost("initial")
	if _, err = rt.RequestVisit(guest.AccountID, host.AccountID); err != nil {
		t.Fatal(err)
	}
	if snap := syncHost("arrival"); len(snap.Pets) != 2 {
		t.Fatalf("arrival pets=%d", len(snap.Pets))
	}
	conn.CloseNow() // No graceful WebSocket close handshake.
	for deadline := time.Now().Add(6 * time.Second); time.Now().Before(deadline); {
		snap, err := rt.Snapshot(guest.AccountID, "g-device", "guest-session", "return")
		if err != nil {
			t.Fatal(err)
		}
		if snap.Own.Phase == "home" && len(snap.Pets) == 1 {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("guest did not return after abrupt host transport loss")
}

func TestRelationshipRemovalRacesAvatarStart(t *testing.T) {
	s, rt, owner, requester, _, envelope := connectAvatarFixture(t)
	task, err := rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, envelope)
	if err != nil {
		t.Fatal(err)
	}
	if err = rt.RespondAvatar(owner.AccountID, task.ID, true); err != nil {
		t.Fatal(err)
	}
	gate := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); <-gate; _ = rt.StartAvatar(owner.AccountID, task.ID) }()
	close(gate)
	if err = s.RemoveFriend(requester.AccountID, owner.AccountID); err != nil {
		t.Fatal(err)
	}
	wg.Wait()
	got, err := s.AvatarTask(task.ID)
	if err != nil || got.State != AvatarRevoked {
		t.Fatalf("race left task %s: %v", got.State, err)
	}
	if s.CompleteAvatarTask(owner.AccountID, task.ID, strings.Repeat("a", 64)) == nil {
		t.Fatal("late result accepted")
	}
}
