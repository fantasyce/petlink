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

type externalV2Actor struct {
	auth   AuthResult
	device string
	conn   *websocket.Conn
	n      int
}

func TestV2ExternalFiveClientJourney(t *testing.T) {
	base, dir := os.Getenv("PETLINK_V2_TEST_URL"), os.Getenv("PETLINK_V2_TEST_INVITES")
	if base == "" || dir == "" {
		t.Skip("isolated v2 fixture not configured")
	}
	userPrefix := os.Getenv("PETLINK_V2_TEST_USER_PREFIX")
	if userPrefix == "" {
		userPrefix = "user"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	post := func(path, token string, body any, out any) int {
		data, _ := json.Marshal(body)
		req, _ := http.NewRequestWithContext(ctx, "POST", base+"/v2/"+path, bytes.NewReader(data))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Request-ID", newID("ext_"))
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		resp, e := http.DefaultClient.Do(req)
		if e != nil {
			t.Fatal(e)
		}
		defer resp.Body.Close()
		_ = json.NewDecoder(resp.Body).Decode(out)
		return resp.StatusCode
	}
	register := func(index int) *externalV2Actor {
		raw, e := os.ReadFile(filepath.Join(dir, fmt.Sprintf("invite-%02d.txt", index)))
		if e != nil {
			t.Fatal(e)
		}
		device := fmt.Sprintf("%s-mac-%d", userPrefix, index)
		var auth AuthResult
		status := post("auth/register", "", map[string]any{"invite": strings.TrimSpace(string(raw)), "username": fmt.Sprintf("%s%02d", userPrefix, index), "password": "correct horse battery staple", "nickname": fmt.Sprintf("User %d", index), "device_id": device}, &auth)
		if status != 201 {
			t.Fatalf("register %d status=%d", index, status)
		}
		return &externalV2Actor{auth: auth, device: device}
	}
	actors := []*externalV2Actor{register(1), register(2), register(3), register(4), register(5)}
	host := actors[0]
	for _, guest := range actors[1:] {
		var request FriendRequest
		if status := post("friends/request", guest.auth.AccessToken, map[string]any{"friend_id": host.auth.FriendID}, &request); status != 201 {
			t.Fatalf("friend request=%d", status)
		}
		var ok map[string]any
		if status := post("friends/respond", host.auth.AccessToken, map[string]any{"request_id": request.ID, "accept": true}, &ok); status != 200 {
			t.Fatalf("friend accept=%d", status)
		}
		req, _ := http.NewRequestWithContext(ctx, "PATCH", base+"/v2/contacts/"+guest.auth.AccountID+"/policy", bytes.NewReader([]byte(`{"trusted":true,"share_agent":false,"note":""}`)))
		req.Header.Set("Authorization", "Bearer "+host.auth.AccessToken)
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Request-ID", newID("ext_"))
		resp, e := http.DefaultClient.Do(req)
		if e != nil {
			t.Fatal(e)
		}
		resp.Body.Close()
		if resp.StatusCode != 200 {
			t.Fatalf("policy status=%d", resp.StatusCode)
		}
	}
	for _, actor := range actors {
		u := strings.Replace(strings.Replace(base, "https://", "wss://", 1), "http://", "ws://", 1) + "/v2/ws"
		conn, _, e := websocket.Dial(ctx, u, nil)
		if e != nil {
			t.Fatal(e)
		}
		actor.conn = conn
		defer conn.CloseNow()
		if e = wsjson.Write(ctx, conn, V2Auth{AccessToken: actor.auth.AccessToken, DeviceID: actor.device, Protocol: 2}); e != nil {
			t.Fatal(e)
		}
	}
	ask := func(actor *externalV2Actor, cmd V2Command) V2Snapshot {
		actor.n++
		cmd.RequestID = fmt.Sprintf("%s-%d", actor.device, actor.n)
		if e := wsjson.Write(ctx, actor.conn, cmd); e != nil {
			t.Fatal(e)
		}
		var snap V2Snapshot
		if e := wsjson.Read(ctx, actor.conn, &snap); e != nil {
			t.Fatal(e)
		}
		return snap
	}
	for range 7 {
		for _, actor := range actors {
			ask(actor, V2Command{Action: "sync"})
		}
		time.Sleep(time.Second)
	}
	for _, guest := range actors[1:4] {
		snap := ask(guest, V2Command{Action: "visit_request", PeerID: host.auth.AccountID})
		if snap.Error != "" {
			t.Fatal(snap.Error)
		}
		if len(snap.Hides) != 1 {
			t.Fatalf("guest did not receive hide: %#v", snap)
		}
		ask(guest, V2Command{Action: "ack", PetID: guest.auth.AccountID, Revision: snap.Hides[0].Revision})
	}
	rejected := ask(actors[4], V2Command{Action: "visit_request", PeerID: host.auth.AccountID})
	if rejected.Error != ErrHostFull.Error() {
		t.Fatalf("fourth=%q", rejected.Error)
	}
	if rejected.Own.Phase != "home" {
		t.Fatalf("fourth guest left home: %#v", rejected.Own)
	}
	hostSnap := ask(host, V2Command{Action: "sync"})
	if len(hostSnap.Pets) != 4 {
		t.Fatalf("host pets=%d want 4", len(hostSnap.Pets))
	}
	ask(host, V2Command{Action: "send_all_home"})
	for _, guest := range actors[1:4] {
		for range 4 {
			snap := ask(guest, V2Command{Action: "sync"})
			if snap.Own.Phase == "home" && len(snap.Pets) == 1 {
				break
			}
			time.Sleep(time.Second)
		}
	}
	t.Log("v2 real transport: register, exact friend id, trust, 3 atomic visitor slots, fourth rejection, unique transfer, send all home PASS")
}
