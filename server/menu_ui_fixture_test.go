package main

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// Opt-in local UI fixture. Never connects to the public service.
func TestMenuUIFixture(t *testing.T) {
	root := os.Getenv("PETLINK_MENU_UI_ROOT")
	if root == "" {
		t.Skip("isolated native menu UI fixture not requested")
	}
	profile := os.Getenv("PETLINK_MENU_UI_PROFILE")
	if profile == "" {
		profile = "menu-ui-20260929"
	}
	if filepath.Base(profile) != profile || profile == "default" {
		t.Fatal("test profile must be isolated")
	}
	dual := os.Getenv("PETLINK_MENU_UI_DUAL") == "1"
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	identity := filepath.Join(home, "Library/Application Support/PetLink/Identity", profile)
	if err = os.Mkdir(identity, 0700); err != nil {
		t.Fatal(err)
	}
	defer os.Remove(identity)
	defer os.Remove(filepath.Join(identity, "session"))
	domain := "com.fantasyce.petlink." + profile
	if err = exec.Command("defaults", "write", domain, "device-id", "menu-device").Run(); err != nil {
		t.Fatal(err)
	}
	defer exec.Command("defaults", "delete", domain).Run()
	s := newTestSocial(t)
	owner := registerTestUser(t, s, "menu-owner", "menuowner", "menu-device")
	peer := registerTestUser(t, s, "menu-peer", "menufriend", "peer-device")
	if dual {
		peerProfile := profile + "-peer"
		peerIdentity := filepath.Join(home, "Library/Application Support/PetLink/Identity", peerProfile)
		if err = os.Mkdir(peerIdentity, 0700); err != nil {
			t.Fatal(err)
		}
		defer os.Remove(peerIdentity)
		defer os.Remove(filepath.Join(peerIdentity, "session"))
		peerDomain := "com.fantasyce.petlink." + peerProfile
		if err = exec.Command("defaults", "write", peerDomain, "device-id", "peer-device").Run(); err != nil {
			t.Fatal(err)
		}
		defer exec.Command("defaults", "delete", peerDomain).Run()
		peerSession, _ := json.Marshal(map[string]string{"accountID": peer.AccountID, "friendID": peer.FriendID, "accessToken": peer.AccessToken, "refreshToken": peer.RefreshToken})
		if err = os.WriteFile(filepath.Join(peerIdentity, "session"), peerSession, 0600); err != nil {
			t.Fatal(err)
		}
	}
	_, err = s.db.Exec(`UPDATE accounts SET nickname='小满' WHERE id=?`, owner.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.db.Exec(`UPDATE accounts SET nickname='阿青' WHERE id=?`, peer.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	makeFriends(t, s, owner, peer)
	if err = s.SetContactPolicy(peer.AccountID, owner.AccountID, ContactPolicy{Trusted: true}); err != nil {
		t.Fatal(err)
	}
	session, _ := json.Marshal(map[string]string{"accountID": owner.AccountID, "friendID": owner.FriendID, "accessToken": owner.AccessToken, "refreshToken": owner.RefreshToken})
	if err = os.WriteFile(filepath.Join(identity, "session"), session, 0600); err != nil {
		t.Fatal(err)
	}
	rt := NewSocialRuntime(s)
	rt.readyAt = time.Now()
	if !dual {
		if err = rt.Connect(peer.AccountID, "peer-device", "peer-ui"); err != nil {
			t.Fatal(err)
		}
	}
	ts := httptest.NewServer(SocialHandlerWithRuntime(s, rt))
	defer ts.Close()
	if err = os.WriteFile(filepath.Join(root, "endpoint"), []byte(ts.URL), 0600); err != nil {
		t.Fatal(err)
	}
	t.Log("local UI fixture ready; stop by creating stop file in fixture root")
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	lifetime := 20 * time.Minute
	if value := os.Getenv("PETLINK_MENU_UI_LIFETIME"); value != "" {
		duration, parseErr := time.ParseDuration(value)
		if parseErr != nil || duration <= 0 || duration > 2*time.Hour {
			t.Fatal("invalid UI fixture lifetime")
		}
		lifetime = duration
	}
	deadline := time.After(lifetime)
	for {
		select {
		case <-deadline:
			return
		case <-ticker.C:
			if _, requestErr := os.Stat(filepath.Join(root, "request-visit")); requestErr == nil {
				if _, requestErr = rt.RequestVisit(peer.AccountID, owner.AccountID); requestErr == nil {
					_ = os.Remove(filepath.Join(root, "request-visit"))
				}
			}
			if _, err = os.Stat(filepath.Join(root, "stop")); err == nil {
				return
			}
			if dual {
				continue
			}
			snap, syncErr := rt.Snapshot(peer.AccountID, "peer-device", "peer-ui", "heartbeat")
			if syncErr == nil {
				for _, hide := range snap.Hides {
					_ = rt.AckHide(peer.AccountID, "peer-device", "peer-ui", hide.PetID, hide.Revision)
				}
			}
		}
	}
}
