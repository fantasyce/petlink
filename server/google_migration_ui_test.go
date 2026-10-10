package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"
)

// Reproduces an expired legacy login through the real Store/HTTP routes.
// The external Google boundary returns unavailable so this fixture never
// starts a real OAuth exchange or creates a Google identity.
func TestGoogleMigrationNativeUIFixture(t *testing.T) {
	root := os.Getenv("PETLINK_LOGIN_UI_ROOT")
	if root == "" {
		t.Skip("opt-in isolated expired-legacy native login fixture")
	}
	profile := "google-entry-qa-20260930"
	s, a, _ := googleTestService(t)
	s.googleOnly.Store(false)
	old := registerTestUser(t, s, "expired-legacy-ui", "legacyuitest", "legacy-ui-device")
	if _, err := s.db.Exec(`UPDATE sessions SET access_expires=0 WHERE account_id=?`, old.AccountID); err != nil {
		t.Fatal(err)
	}
	actual := GoogleHandler(a)
	var proofs, begins atomic.Int32
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/v2/auth/migration/prove" {
			proofs.Add(1)
		}
		if r.URL.Path == "/v2/auth/google/begin" {
			begins.Add(1)
			googleError(w, ErrGoogleUnavailable)
			return
		}
		actual.ServeHTTP(w, r)
	}))
	defer ts.Close()
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Join(home, "Library/Application Support/PetLink/Identity", profile)
	if err = os.Mkdir(dir, 0700); err != nil {
		t.Fatal("QA profile must be fresh")
	}
	defer os.Remove(dir)
	defer os.Remove(filepath.Join(dir, "session"))
	domain := "com.fantasyce.petlink." + profile
	defer exec.Command("defaults", "delete", domain).Run()
	for key, value := range map[string]string{"device-id": "legacy-ui-device", "endpoint": ts.URL} {
		if err = exec.Command("defaults", "write", domain, key, "-string", value).Run(); err != nil {
			t.Fatal(err)
		}
	}
	data, _ := json.Marshal(map[string]string{"accountID": old.AccountID, "friendID": old.FriendID, "accessToken": old.AccessToken, "refreshToken": old.RefreshToken})
	if err = os.WriteFile(filepath.Join(dir, "session"), data, 0600); err != nil {
		t.Fatal(err)
	}
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	deadline := time.After(15 * time.Minute)
	for {
		select {
		case <-deadline:
			return
		case <-ticker.C:
			stats, _ := json.Marshal(map[string]int32{"migration_proofs": proofs.Load(), "google_begins": begins.Load()})
			if err = os.WriteFile(filepath.Join(root, "stats.json"), stats, 0600); err != nil {
				t.Fatal(err)
			}
			if _, err = os.Stat(filepath.Join(root, "stop")); err == nil {
				return
			}
		}
	}
}
