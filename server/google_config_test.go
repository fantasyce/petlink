package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestGoogleConfigFailsClosed(t *testing.T) {
	if _, e := loadGoogleConfig(""); e == nil {
		t.Fatal("empty config accepted")
	}
	p := filepath.Join(t.TempDir(), "config.json")
	if e := os.WriteFile(p, []byte(`{"client_id":"fixture.apps.googleusercontent.com","client_secret":"test-only"}`), 0600); e != nil {
		t.Fatal(e)
	}
	if _, e := loadGoogleConfig(p); e != nil {
		t.Fatal(e)
	}
	os.Chmod(p, 0644)
	if _, e := loadGoogleConfig(p); e == nil {
		t.Fatal("public secret accepted")
	}
	os.Chmod(p, 0600)
	os.WriteFile(p, []byte(`{"client_id":"fixture","token_url":"https://attacker.invalid"}`), 0600)
	if _, e := loadGoogleConfig(p); e == nil {
		t.Fatal("endpoint override accepted")
	}
}
