package main

import (
	"context"
	"fmt"
	"net/http/httptest"
	"os"
	"runtime"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

// This is Google-mode protocol capacity evidence, not a live OAuth or VPS test.
func TestGoogleAcceptanceCapacity(t *testing.T) {
	raw := os.Getenv("PETLINK_GOOGLE_SOAK_DURATION")
	if raw == "" {
		t.Skip("opt-in Google capacity soak")
	}
	d, err := time.ParseDuration(raw)
	if err != nil || d < time.Hour || d > 70*time.Minute {
		t.Fatal("Google release soak requires 60–70 minutes")
	}
	runGoogleCapacity(t, d, 10*time.Minute)
}

func TestGoogleCapacityHarnessSmoke(t *testing.T) {
	runGoogleCapacity(t, 9*time.Second, 2*time.Second)
}

func runGoogleCapacity(t *testing.T, duration, refreshEvery time.Duration) {
	s, service, handler := googleTestService(t)
	service.Runtime.readyAt = time.Now()
	ts := httptest.NewServer(handler)
	defer ts.Close()
	accounts := make([]AuthResult, 20)
	connections := make([]*websocket.Conn, 10)
	defer func() {
		for _, c := range connections {
			if c != nil {
				c.CloseNow()
			}
		}
	}()
	connect := func(i int) {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		c, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/v2/ws", nil)
		if err != nil {
			t.Fatal("connect failed", err)
		}
		connections[i] = c
		if err := wsjson.Write(ctx, c, V2Auth{AccessToken: accounts[i].AccessToken, DeviceID: fmt.Sprintf("google-soak-%d", i), Protocol: 2}); err != nil {
			t.Fatal("authenticate failed", err)
		}
	}
	for i := range accounts {
		id, _, err := s.ResolveGoogle(GoogleIdentity{"https://accounts.google.com", fmt.Sprintf("soak-subject-%d", i), fmt.Sprintf("soak%d@example.invalid", i)}, fmt.Sprintf("Fixture%d", i))
		if err != nil {
			t.Fatal(err)
		}
		accounts[i], err = service.Runtime.IssueGoogleSession(id, fmt.Sprintf("google-soak-%d", i), false)
		if err != nil {
			t.Fatal(err)
		}
		if i < len(connections) {
			connect(i)
		}
	}
	start := time.Now()
	nextRefresh, nextProgress := start.Add(refreshEvery), start.Add(5*time.Minute)
	latencies := make([]time.Duration, 0, 50000)
	rounds, rotations := 0, 0
	permitRecoveryUntil := time.Time{}
	lastVisible := make([]bool, len(connections))
	for time.Since(start) < duration {
		if time.Now().After(nextRefresh) {
			for i := range connections {
				status, out := googleRequest(t, handler, "refresh", map[string]any{"refresh_token": accounts[i].RefreshToken}, "")
				if status != 200 {
					t.Fatal("refresh failed", status)
				}
				access, aok := out["access_token"].(string)
				refresh, rok := out["refresh_token"].(string)
				if !aok || !rok || access == "" || refresh == "" {
					t.Fatal("invalid refresh response")
				}
				connections[i].CloseNow()
				accounts[i].AccessToken, accounts[i].RefreshToken = access, refresh
				connect(i)
				rotations++
			}
			nextRefresh = time.Now().Add(refreshEvery)
			if duration < time.Minute {
				nextRefresh = start.Add(duration)
			}
			// A prior socket retains its five-second lease. The replacement must
			// wait for it, not manufacture overlapping display permission.
			permitRecoveryUntil = time.Now().Add(6 * time.Second)
		}
		for i, c := range connections {
			began := time.Now()
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			err := wsjson.Write(ctx, c, V2Command{RequestID: fmt.Sprintf("capacity-%d-%d", i, rounds), Action: "sync"})
			var snap V2Snapshot
			if err == nil {
				err = wsjson.Read(ctx, c, &snap)
			}
			cancel()
			lastVisible[i] = len(snap.Pets) == 1
			validCount := lastVisible[i] || (len(snap.Pets) == 0 && time.Now().Before(permitRecoveryUntil))
			if err != nil || snap.Error != "" || snap.SelfID != accounts[i].AccountID || !validCount {
				t.Fatalf("client %d invalid snapshot: transport=%v error=%s pets=%d", i, err, snap.Error, len(snap.Pets))
			}
			latencies = append(latencies, time.Since(began))
		}
		rounds++
		if time.Now().After(nextProgress) {
			t.Logf("progress elapsed=%s rounds=%d rotations=%d", time.Since(start).Round(time.Second), rounds, rotations)
			nextProgress = time.Now().Add(5 * time.Minute)
		}
		time.Sleep(250 * time.Millisecond)
	}
	if rotations == 0 {
		t.Fatal("refresh path not exercised")
	}
	for i, visible := range lastVisible {
		if !visible {
			t.Fatalf("client %d did not recover display", i)
		}
	}
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
	p95 := latencies[len(latencies)*95/100]
	if p95 > 2*time.Second {
		t.Fatal("P95 exceeds 2s", p95)
	}
	var memory runtime.MemStats
	runtime.ReadMemStats(&memory)
	t.Logf("Google mode: accounts=20 online=10 duration=%s samples=%d rotations=%d p95=%s heapMiB=%d", time.Since(start), len(latencies), rotations, p95, memory.HeapAlloc/(1024*1024))
}
