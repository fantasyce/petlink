package main

import (
	"encoding/json"
	"testing"
	"time"
)

func TestContactPetAppearanceFollowsCurrentStyle(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "style-a", "alice", "mac-a")
	b := registerTestUser(t, s, "style-b", "bob", "mac-b")
	makeFriends(t, s, a, b)
	rt := NewSocialRuntime(s)
	rt.readyAt = time.Now()
	if e := rt.Connect(a.AccountID, "mac-a", "style-session"); e != nil {
		t.Fatal(e)
	}
	for _, style := range []int{6, 7, 9, 0} {
		if e := rt.Style(b.AccountID, style); e != nil {
			t.Fatal(e)
		}
		snapshot, e := rt.Snapshot(a.AccountID, "mac-a", "style-session", "style-request")
		if e != nil {
			t.Fatal(e)
		}
		data, e := json.Marshal(snapshot)
		if e != nil {
			t.Fatal(e)
		}
		var value struct {
			Contacts []map[string]any `json:"contacts"`
		}
		if e = json.Unmarshal(data, &value); e != nil {
			t.Fatal(e)
		}
		if len(value.Contacts) != 1 || value.Contacts[0]["style"] != float64(style) {
			t.Fatalf("contact must carry current pet style %d", style)
		}
		if value.Contacts[0]["account_id"] != b.AccountID || value.Contacts[0]["nickname"] != "bob" {
			t.Fatal("style update changed friend identity")
		}
	}
}

func TestProfilePetAppearanceWithoutSocialConnection(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "profile-style", "alice", "mac-a")
	rt := NewSocialRuntime(s)
	if e := rt.Style(a.AccountID, 7); e != nil {
		t.Fatal(e)
	}
	profile, e := s.Profile(a.AccountID)
	if e != nil {
		t.Fatal(e)
	}
	data, e := json.Marshal(profile)
	if e != nil {
		t.Fatal(e)
	}
	var payload map[string]any
	if e = json.Unmarshal(data, &payload); e != nil {
		t.Fatal(e)
	}
	if payload["style"] != float64(7) {
		t.Fatal("own appearance must be readable without starting a social connection")
	}
}
