package main

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// A local-only backend and accounts for exercising the shipped native controls.
// Session files are scoped to fresh QA profiles, never the user's real account.
func TestAvatarAuthorizationNativeUIFixture(t *testing.T) {
	root := os.Getenv("PETLINK_AVATAR_UI_ROOT")
	if root == "" {
		t.Skip("opt-in isolated native avatar authorization fixture")
	}
	profile := os.Getenv("PETLINK_AVATAR_UI_PROFILE")
	if profile == "" {
		profile = "avatar-consent-qa-20260930"
	}
	if filepath.Base(profile) != profile || profile == "default" {
		t.Fatal("test profile must be isolated")
	}
	s := newTestSocial(t)
	a := registerTestUser(t, s, "avatar-ui-a", "avataralice", "avatar-ui-a")
	b := registerTestUser(t, s, "avatar-ui-b", "avatarbob", "avatar-ui-b")
	c := registerTestUser(t, s, "avatar-ui-c", "avatarcarol", "avatar-ui-c")
	makeFriends(t, s, a, b)
	makeFriends(t, s, a, c)
	if os.Getenv("PETLINK_INVALID_SESSION_TEST") == "1" {
		if _, err := s.db.Exec(`UPDATE sessions SET revoked=1`); err != nil {
			t.Fatal(err)
		}
	}
	chatTest := os.Getenv("PETLINK_CONTACT_CHAT_TEST") == "1"
	var chatPeers []AuthResult
	if chatTest {
		d := registerTestUser(t, s, "chat-ui-d", "chatdiana", "chat-ui-d")
		e := registerTestUser(t, s, "chat-ui-e", "chaterin", "chat-ui-e")
		makeFriends(t, s, a, d)
		makeFriends(t, s, a, e)
		chatPeers = []AuthResult{c, d}
		for id, name := range map[string]string{c.AccountID: "小叶", d.AccountID: "未开启的好友", e.AccountID: "离线好友"} {
			if _, err := s.db.Exec(`UPDATE accounts SET nickname=? WHERE id=?`, name, id); err != nil {
				t.Fatal(err)
			}
		}
	}
	if _, err := s.db.Exec(`UPDATE accounts SET nickname='小满' WHERE id=?`, a.AccountID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`UPDATE accounts SET nickname='阿青' WHERE id=?`, b.AccountID); err != nil {
		t.Fatal(err)
	}
	if !chatTest {
		if _, err := s.db.Exec(`UPDATE accounts SET nickname='未开启的好友' WHERE id=?`, c.AccountID); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.SetContactPolicy(a.AccountID, b.AccountID, ContactPolicy{Trusted: true}); err != nil {
		t.Fatal(err)
	}
	renewalTest := os.Getenv("PETLINK_CREDENTIAL_RENEWAL_TEST") == "1"
	appearanceTest := os.Getenv("PETLINK_APPEARANCE_TEST") == "1"
	if appearanceTest {
		if _, err := s.db.Exec(`UPDATE pets SET style=6 WHERE owner_id=?`, a.AccountID); err != nil {
			t.Fatal(err)
		}
		if _, err := s.db.Exec(`UPDATE pets SET style=9 WHERE owner_id=?`, b.AccountID); err != nil {
			t.Fatal(err)
		}
	}
	if renewalTest {
		if _, err := s.db.Exec(`UPDATE accounts SET auth_method='google'`); err != nil {
			t.Fatal(err)
		}
		s.googleOnly.Store(true)
	}
	rt := NewSocialRuntime(s)
	rt.readyAt = time.Now()
	for _, peer := range chatPeers {
		p, err := s.Profile(peer.AccountID)
		if err != nil {
			t.Fatal(err)
		}
		if err = rt.Connect(peer.AccountID, p.ActiveDevice, "chat-"+peer.AccountID); err != nil {
			t.Fatal(err)
		}
	}
	// Keep hijacked WebSocket connections in this test's set so an opt-in
	// transport interruption can exercise native reconnect without changing
	// the host network or the user's service.
	var connectionsMu sync.Mutex
	connections := map[net.Conn]bool{}
	handler := SocialHandlerWithRuntime(s, rt)
	var rotations atomic.Int32
	ts := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if renewalTest && r.URL.Path == "/v2/auth/refresh" {
			rotations.Add(1)
			if _, e := os.Stat(filepath.Join(root, "slow-refresh")); e == nil {
				// Delay AFTER the production refresh commits and revokes the old
				// token, including repeated renewal controls during the delay.
				recorder := httptest.NewRecorder()
				handler.ServeHTTP(recorder, r)
				time.Sleep(4 * time.Second)
				for key, values := range recorder.Header() {
					w.Header()[key] = values
				}
				w.WriteHeader(recorder.Code)
				_, _ = w.Write(recorder.Body.Bytes())
				return
			}
		}
		if renewalTest && r.URL.Path == "/v2/me" {
			if _, e := os.Stat(filepath.Join(root, "late-profile")); e == nil {
				time.Sleep(5 * time.Second)
			}
		}
		handler.ServeHTTP(w, r)
	}))
	ts.Config.ConnState = func(c net.Conn, state http.ConnState) {
		connectionsMu.Lock()
		defer connectionsMu.Unlock()
		if state == http.StateClosed {
			delete(connections, c)
		} else {
			connections[c] = true
		}
	}
	ts.Start()
	defer ts.Close()
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	for i, user := range []AuthResult{a, b} {
		p := profile
		device := "avatar-ui-a"
		if i == 1 {
			p += "-peer"
			device = "avatar-ui-b"
		}
		dir := filepath.Join(home, "Library/Application Support/PetLink/Identity", p)
		if err = os.Mkdir(dir, 0700); err != nil {
			t.Fatal("QA profile already exists or cannot be created")
		}
		defer os.Remove(dir)
		defer os.Remove(filepath.Join(dir, "session"))
		domain := "com.fantasyce.petlink." + p
		if err = exec.Command("defaults", "write", domain, "device-id", "-string", device).Run(); err != nil {
			t.Fatal(err)
		}
		if err = exec.Command("defaults", "write", domain, "endpoint", "-string", ts.URL).Run(); err != nil {
			t.Fatal(err)
		}
		defer exec.Command("defaults", "delete", domain).Run()
		data, _ := json.Marshal(map[string]string{"accountID": user.AccountID, "friendID": user.FriendID, "accessToken": user.AccessToken, "refreshToken": user.RefreshToken})
		if err = os.WriteFile(filepath.Join(dir, "session"), data, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err = os.WriteFile(filepath.Join(root, "endpoint"), []byte(ts.URL), 0600); err != nil {
		t.Fatal(err)
	}
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	duration := 20 * time.Minute
	if chatTest {
		duration = 45 * time.Minute
	}
	deadline := time.After(duration)
	connectionDrops := 0
	for {
		select {
		case <-deadline:
			return
		case <-ticker.C:
			for _, peer := range chatPeers {
				p, _ := s.Profile(peer.AccountID)
				snap, err := rt.Snapshot(peer.AccountID, p.ActiveDevice, "chat-"+peer.AccountID, "heartbeat")
				if err == nil {
					for _, hide := range snap.Hides {
						_ = rt.AckHide(peer.AccountID, p.ActiveDevice, "chat-"+peer.AccountID, hide.PetID, hide.Revision)
					}
				}
			}
			if chatTest {
				for _, name := range []string{"visit-unopened", "prepare-second", "depart-peer"} {
					path := filepath.Join(root, name)
					if _, err := os.Stat(path); err != nil {
						continue
					}
					if name == "depart-peer" {
						_ = rt.Recall(b.AccountID)
					}
					if name == "visit-unopened" {
						_, _ = s.db.Exec(`UPDATE pets SET location_id=?,target_id=?,phase='visit',revision=revision+1 WHERE owner_id=?`, a.AccountID, a.AccountID, chatPeers[1].AccountID)
					}
					if name == "prepare-second" {
						key, err := s.ActiveDeviceKey(b.AccountID)
						if err != nil {
							continue
						}
						// Isolated UI eligibility/draft fixture; only public keys are reused.
						if _, err = s.RegisterDeviceKeys(c.AccountID, "avatar-ui-c", key.AgreementPublicKey, key.SigningPublicKey); err != nil {
							t.Fatal(err)
						}
						_, _ = s.db.Exec(`UPDATE pets SET location_id=?,target_id=?,phase='visit',revision=revision+1 WHERE owner_id=?`, a.AccountID, a.AccountID, c.AccountID)
					}
					_ = os.Remove(path)
				}
			}
			if renewalTest {
				for name, id := range map[string]string{"self": a.AccountID, "peer": b.AccountID} {
					path := filepath.Join(root, "expire-"+name)
					if _, e := os.Stat(path); e == nil {
						if _, e = s.db.Exec(`UPDATE sessions SET access_expires=? WHERE account_id=? AND revoked=0`, time.Now().Add(-time.Second).UnixMilli(), id); e != nil {
							t.Fatal(e)
						}
						_ = os.Remove(path)
					}
				}
			}
			if _, e := os.Stat(filepath.Join(root, "drop-connections")); e == nil {
				connectionsMu.Lock()
				live := make([]net.Conn, 0, len(connections))
				for c := range connections {
					live = append(live, c)
				}
				connections = map[net.Conn]bool{}
				connectionsMu.Unlock()
				for _, c := range live {
					_ = c.Close()
				}
				connectionDrops++
				_ = os.Remove(filepath.Join(root, "drop-connections"))
			}
			stats := map[string]any{}
			stats["credential_rotations"] = rotations.Load()
			stats["connection_drops"] = connectionDrops
			for name, id := range map[string]string{"self": a.AccountID, "peer": b.AccountID, "unopened": c.AccountID} {
				_, e := s.ActiveDeviceKey(id)
				stats[name+"_ready"] = e == nil
			}
			var count, consentCount int
			_ = s.db.QueryRow(`SELECT count(*) FROM device_keys`).Scan(&count)
			_ = s.db.QueryRow(`SELECT count(*) FROM avatar_authorizations`).Scan(&consentCount)
			stats["key_records"] = count
			stats["consent_records"] = consentCount
			var states []string
			rows, e := s.db.Query(`SELECT state FROM avatar_tasks ORDER BY created_at`)
			if e == nil {
				for rows.Next() {
					var state string
					_ = rows.Scan(&state)
					states = append(states, state)
				}
				rows.Close()
			}
			stats["task_states"] = states
			data, _ := json.Marshal(stats)
			_ = os.WriteFile(filepath.Join(root, "stats.json"), data, 0600)
			if _, err = os.Stat(filepath.Join(root, "stop")); err == nil {
				return
			}
		}
	}
}
