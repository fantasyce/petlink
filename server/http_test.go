package main

import (
	"context"
	"encoding/json"
	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestHealthReflectsStorageFailure(t *testing.T) {
	h, _ := fixture(t)
	h.db.Close()
	h.Snapshot("a", "sa")
	req := httptest.NewRequest("GET", "/health", nil)
	w := httptest.NewRecorder()
	Handler(h).ServeHTTP(w, req)
	if w.Code != 503 {
		t.Fatalf("expected unavailable after storage failure, got %d", w.Code)
	}
}

func TestPairOneTime(t *testing.T) {
	h, _ := fixture(t)
	must(t, h.AddInvitation("c", "C", "test-pair"))
	id, token, e := h.Pair("test-pair")
	must(t, e)
	if id != "c" || h.Auth(token) != "c" {
		t.Fatal("pair failed")
	}
	if _, _, e = h.Pair("test-pair"); e == nil {
		t.Fatal("code reused")
	}
}
func TestWebSocketAuthenticationAndState(t *testing.T) {
	h, _ := fixture(t)
	srv := httptest.NewServer(Handler(h))
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	url := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
	c, _, e := websocket.Dial(ctx, url, nil)
	must(t, e)
	defer c.CloseNow()
	must(t, wsjson.Write(ctx, c, map[string]string{"token": "wrong"}))
	var raw json.RawMessage
	if wsjson.Read(ctx, c, &raw) == nil {
		t.Fatal("bad auth accepted")
	}
	c, _, e = websocket.Dial(ctx, url, nil)
	must(t, e)
	defer c.CloseNow()
	must(t, wsjson.Write(ctx, c, map[string]string{"token": "token-a"}))
	must(t, wsjson.Write(ctx, c, Command{ID: "1", Action: "sync"}))
	var s Snapshot
	must(t, wsjson.Read(ctx, c, &s))
	if s.Self != "a" || s.ID != "1" {
		t.Fatal("invalid state")
	}
}
