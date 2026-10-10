package main

import (
	"context"
	"fmt"
	"net/http/httptest"
	"os"
	"runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

// TestV2TenClientSoak is deliberately opt-in so ordinary builds remain fast.
// Release validation runs it for 60 minutes against 20 accounts / 10 sockets.
func TestV2TenClientSoak(t *testing.T) {
	raw := os.Getenv("PETLINK_SOAK_DURATION")
	if raw == "" {
		t.Skip("set PETLINK_SOAK_DURATION for release soak")
	}
	duration, err := time.ParseDuration(raw)
	if err != nil || duration <= 0 {
		t.Fatalf("invalid PETLINK_SOAK_DURATION=%q", raw)
	}
	s := newTestSocial(t)
	accounts := make([]AuthResult, 20)
	for i := range accounts {
		accounts[i] = registerTestUser(t, s, newID("soak-invite-"), fmt.Sprintf("soak%02d", i), fmt.Sprintf("soak-mac-%02d", i))
	}
	rt := NewSocialRuntime(s)
	rt.readyAt = time.Now()
	ts := httptest.NewServer(SocialHandlerWithRuntime(s, rt))
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), duration+30*time.Second)
	defer cancel()
	connections := make([]*websocket.Conn, 10)
	for i := range connections {
		conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/v2/ws", nil)
		if err != nil {
			t.Fatal(err)
		}
		connections[i] = conn
		defer conn.CloseNow()
		if err = wsjson.Write(ctx, conn, V2Auth{AccessToken: accounts[i].AccessToken, DeviceID: fmt.Sprintf("soak-mac-%02d", i), Protocol: 2}); err != nil {
			t.Fatal(err)
		}
	}

	var latenciesMu sync.Mutex
	latencies := make([]time.Duration, 0, int(duration/time.Second)*10)
	var failures atomic.Int64
	deadline := time.Now().Add(duration)
	var wg sync.WaitGroup
	for i, conn := range connections {
		wg.Add(1)
		go func(index int, c *websocket.Conn) {
			defer wg.Done()
			sequence := 0
			for time.Now().Before(deadline) {
				sequence++
				started := time.Now()
				opCtx, opCancel := context.WithTimeout(ctx, 3*time.Second)
				err := wsjson.Write(opCtx, c, V2Command{RequestID: fmt.Sprintf("soak-%02d-%d", index, sequence), Action: "sync"})
				var snap V2Snapshot
				if err == nil {
					err = wsjson.Read(opCtx, c, &snap)
				}
				opCancel()
				if err != nil || snap.Error != "" || snap.SelfID != accounts[index].AccountID || len(snap.Pets) != 1 {
					failures.Add(1)
					return
				}
				latenciesMu.Lock()
				latencies = append(latencies, time.Since(started))
				latenciesMu.Unlock()
				time.Sleep(900 * time.Millisecond)
			}
		}(i, conn)
	}
	wg.Wait()
	if failures.Load() != 0 {
		t.Fatalf("failures=%d", failures.Load())
	}
	if len(latencies) < 10 {
		t.Fatalf("too few samples: %d", len(latencies))
	}
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	p95 := latencies[(len(latencies)*95)/100]
	if p95 > 2*time.Second {
		t.Fatalf("p95=%s exceeds 2s", p95)
	}
	var memory runtime.MemStats
	runtime.ReadMemStats(&memory)
	t.Logf("20 accounts, 10 online, duration=%s samples=%d p95=%s heap=%dMiB PASS", duration, len(latencies), p95, memory.HeapAlloc/(1024*1024))
}
