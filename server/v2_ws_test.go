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

func TestV2WebSocketAuthenticatesAndReturnsLeaseSnapshot(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "ia", "alice", "mac-a")
	rt := NewSocialRuntime(s)
	rt.readyAt = time.Now()
	ts := httptest.NewServer(SocialHandlerWithRuntime(s, rt))
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, _, e := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/v2/ws", nil)
	if e != nil {
		t.Fatal(e)
	}
	defer c.CloseNow()
	if e = wsjson.Write(ctx, c, V2Auth{AccessToken: a.AccessToken, DeviceID: "mac-a", Protocol: 2}); e != nil {
		t.Fatal(e)
	}
	if e = wsjson.Write(ctx, c, V2Command{RequestID: "sync-1", Action: "sync"}); e != nil {
		t.Fatal(e)
	}
	var snap V2Snapshot
	if e = wsjson.Read(ctx, c, &snap); e != nil {
		t.Fatal(e)
	}
	if snap.RequestID != "sync-1" || snap.SelfID != a.AccountID || len(snap.Pets) != 1 || snap.LeaseMS != 3000 {
		t.Fatalf("snapshot=%#v", snap)
	}
}

func TestV2WebSocketRejectsOldDevice(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "ia", "alice", "mac-a")
	_, _ = s.Takeover(TakeoverInput{Username: "alice", Password: "correct horse battery staple", DeviceID: "mac-new"})
	ts := httptest.NewServer(SocialHandlerWithRuntime(s, NewSocialRuntime(s)))
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, _, e := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/v2/ws", nil)
	if e != nil {
		t.Fatal(e)
	}
	defer c.CloseNow()
	_ = wsjson.Write(ctx, c, V2Auth{AccessToken: a.AccessToken, DeviceID: "mac-a", Protocol: 2})
	var any map[string]any
	if e = wsjson.Read(ctx, c, &any); e == nil {
		t.Fatalf("old device received data: %v", any)
	}
}

func TestV2WebSocketReplaysRequestIDWithoutRepeatingMutation(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "ia", "alice", "mac-a")
	rt := NewSocialRuntime(s)
	rt.readyAt = time.Now()
	ts := httptest.NewServer(SocialHandlerWithRuntime(s, rt))
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, _, e := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/v2/ws", nil)
	if e != nil {
		t.Fatal(e)
	}
	defer c.CloseNow()
	_ = wsjson.Write(ctx, c, V2Auth{AccessToken: a.AccessToken, DeviceID: "mac-a", Protocol: 2})
	command := V2Command{RequestID: "same-wave", Action: "wave"}
	for range 2 {
		if e = wsjson.Write(ctx, c, command); e != nil {
			t.Fatal(e)
		}
		var snap V2Snapshot
		if e = wsjson.Read(ctx, c, &snap); e != nil {
			t.Fatal(e)
		}
		if snap.Own.WaveSequence != 1 {
			t.Fatalf("wave sequence=%d", snap.Own.WaveSequence)
		}
	}
}
