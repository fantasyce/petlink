package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// This test is opt-in because it consumes two single-use test invitations.
// Never point it at already provisioned user identities.
func TestExternalJourney(t *testing.T) {
	base := os.Getenv("PETLINK_TEST_URL")
	dir := os.Getenv("PETLINK_TEST_INVITES")
	if base == "" || dir == "" {
		t.Skip("external fixture not configured; core and HTTP tests run separately")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	type actor struct {
		conn  *websocket.Conn
		token string
		n     int
	}
	connect := func(token string) *websocket.Conn {
		u := strings.Replace(base, "https://", "wss://", 1)
		u = strings.Replace(u, "http://", "ws://", 1)
		c, _, e := websocket.Dial(ctx, u+"/ws", nil)
		must(t, e)
		must(t, wsjson.Write(ctx, c, map[string]string{"token": token}))
		return c
	}
	pair := func(id string) *actor {
		code, e := os.ReadFile(filepath.Join(dir, "pair-"+id+".txt"))
		must(t, e)
		b, _ := json.Marshal(map[string]string{"code": strings.TrimSpace(string(code))})
		r, e := http.Post(base+"/pair", "application/json", bytes.NewReader(b))
		must(t, e)
		defer r.Body.Close()
		if r.StatusCode != 200 {
			t.Fatalf("pair status %d", r.StatusCode)
		}
		var obj map[string]string
		must(t, json.NewDecoder(r.Body).Decode(&obj))
		token := obj["token"]
		if token == "" {
			t.Fatal("missing token")
		}
		must(t, os.WriteFile(filepath.Join(dir, "token-"+id+".txt"), []byte(token), 0600))
		return &actor{conn: connect(token), token: token}
	}
	a, b := pair("a"), pair("b")
	defer a.conn.CloseNow()
	defer b.conn.CloseNow()
	ask := func(a *actor, c Command) Snapshot {
		a.n++
		c.ID = fmt.Sprint(a.n)
		must(t, wsjson.Write(ctx, a.conn, c))
		var s Snapshot
		must(t, wsjson.Read(ctx, a.conn, &s))
		if s.ID != c.ID {
			t.Fatal("wrong correlation")
		}
		return s
	}
	sync := Command{Action: "sync"}
	for i := 0; i < 7; i++ {
		ask(a, sync)
		ask(b, sync)
		time.Sleep(time.Second)
	}
	if s := ask(a, Command{Action: "visit", Peer: "b"}); s.Error == "" {
		t.Fatal("unauthorized visit accepted")
	}
	if s := ask(b, Command{Action: "allow", Peer: "a", Enabled: true}); s.Error != "" {
		t.Fatal(s.Error)
	}
	if s := ask(a, sync); len(s.Pets) != 1 {
		t.Fatal("A home missing")
	}
	s := ask(a, Command{Action: "visit", Peer: "b"})
	if len(s.Pets) != 0 || len(s.Hides) != 1 {
		t.Fatal("departure failed")
	}
	if len(ask(b, sync).Pets) != 1 {
		t.Fatal("duplicate arrival")
	}
	if ask(a, Command{Action: "ack", Pet: "a", Revision: s.Hides[0].Revision - 1}).Error == "" {
		t.Fatal("stale ack accepted")
	}
	ask(a, Command{Action: "ack", Pet: "a", Revision: s.Hides[0].Revision})
	if len(ask(b, sync).Pets) != 2 {
		t.Fatal("arrival failed")
	}
	ask(a, Command{Action: "style", Style: 1})
	s = ask(b, sync)
	found := false
	for _, p := range s.Pets {
		if p.Owner == "a" && p.Style == 1 {
			found = true
		}
	}
	if !found {
		t.Fatal("outfit not relayed")
	}
	ask(a, Command{Action: "wave"})
	s = ask(b, sync)
	for _, p := range s.Pets {
		if p.Owner == "a" && p.Wave != 1 {
			t.Fatal("wave missing")
		}
	}
	s = ask(b, Command{Action: "send_home", Pet: "a"})
	for _, x := range s.Hides {
		ask(b, Command{Action: "ack", Pet: x.Pet, Revision: x.Revision})
	}
	if len(ask(a, sync).Pets) != 1 {
		t.Fatal("return failed")
	}
	s = ask(a, Command{Action: "visit", Peer: "b"})
	for _, x := range s.Hides {
		ask(a, Command{Action: "ack", Pet: x.Pet, Revision: x.Revision})
	}
	if len(ask(b, sync).Pets) != 2 {
		t.Fatal("second arrival failed")
	}
	b.conn.CloseNow()
	for i := 0; i < 7; i++ {
		time.Sleep(time.Second)
		s = ask(a, sync)
	}
	if s.Own.Phase != "home" || len(s.Pets) != 1 {
		t.Fatal("disconnect recovery failed")
	}
	b.conn = connect(b.token)
	defer b.conn.CloseNow()
	ask(b, Command{Action: "allow", Peer: "a", Enabled: false})
	if ask(a, Command{Action: "visit", Peer: "b"}).Error == "" {
		t.Fatal("revoked access still works")
	}
	t.Log("real transport: pairing, auth, grant, unique departure/arrival, stale ack, outfit, wave, return, disconnect recovery, revoke PASS")
}
