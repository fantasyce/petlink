package main

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"testing"
)

func TestGoogleDefaultNicknameAndEdit(t *testing.T) {
	s := newTestSocial(t)
	identity := GoogleIdentity{"https://accounts.google.com", "default-nick-fixture", "nick@example.invalid"}
	id, created, e := s.ResolveGoogle(identity, "")
	if e != nil || !created {
		t.Fatalf("login without nickname: %v", e)
	}
	p, e := s.Profile(id)
	if e != nil || p.Nickname == "" || !p.NicknameIsDefault {
		t.Fatalf("default profile: %+v %v", p, e)
	}
	before := p.Nickname
	again, created, e := s.ResolveGoogle(identity, "ignored")
	if e != nil || created || again != id {
		t.Fatal("identity changed", e)
	}
	p, _ = s.Profile(id)
	if p.Nickname != before {
		t.Fatal("default changed on next login")
	}
	if e = s.SetNickname(id, "  新名字  "); e != nil {
		t.Fatal(e)
	}
	p, _ = s.Profile(id)
	if p.Nickname != "新名字" || p.NicknameIsDefault {
		t.Fatal(p)
	}
	if e = s.SetNickname(id, ""); e != ErrValidation {
		t.Fatal("blank accepted", e)
	}
	_, _, e = s.ResolveGoogle(identity, "")
	if e != nil {
		t.Fatal(e)
	}
	p, _ = s.Profile(id)
	if p.Nickname != "新名字" || p.NicknameIsDefault {
		t.Fatal("existing nickname overwritten")
	}
}

func TestGoogleDefaultNicknameVersionOneUpgrade(t *testing.T) {
	s := newTestSocial(t)
	id, _, e := s.ResolveGoogle(GoogleIdentity{"https://accounts.google.com", "upgrade-fixture", "upgrade@example.invalid"}, "TestB")
	if e != nil {
		t.Fatal(e)
	}
	// Recreate a real v1 schema: no default marker column yet.
	if _, e = s.db.Exec(`ALTER TABLE accounts DROP COLUMN nickname_is_default; UPDATE auth_schema_version SET version=1`); e != nil {
		t.Fatal(e)
	}
	if e = s.MigrateGoogleSchema(); e != nil {
		t.Fatal(e)
	}
	p, e := s.Profile(id)
	if e != nil || p.Nickname != "TestB" || p.NicknameIsDefault {
		t.Fatal(p, e)
	}
}

func TestNicknameAuthenticatedHTTP(t *testing.T) {
	s := newTestSocial(t)
	rt := NewSocialRuntime(s)
	h := SocialHandlerWithRuntime(s, rt)
	identity := GoogleIdentity{"https://accounts.google.com", "http-nick-fixture", "http@example.invalid"}
	id, _, e := s.ResolveGoogle(identity, "")
	if e != nil {
		t.Fatal(e)
	}
	session, e := rt.IssueGoogleSession(id, "nick-device", false)
	if e != nil {
		t.Fatal(e)
	}
	for _, tc := range []struct {
		token, name string
		want        int
	}{{"", "bad", 401}, {session.AccessToken, "", 400}, {session.AccessToken, "新昵称", 200}} {
		body, _ := json.Marshal(map[string]string{"nickname": tc.name})
		r := httptest.NewRequest("PATCH", "/v2/me", bytes.NewReader(body))
		r.Header.Set("X-Request-ID", newID("req_"))
		r.Header.Set("Authorization", "Bearer "+tc.token)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != tc.want {
			t.Fatalf("status %d: %s", w.Code, w.Body.String())
		}
	}
	p, _ := s.Profile(id)
	if p.Nickname != "新昵称" || p.NicknameIsDefault {
		t.Fatal(p)
	}
}

func TestExistingGoogleAccountWithoutNickname(t *testing.T) {
	s := newTestSocial(t)
	identity := GoogleIdentity{"https://accounts.google.com", "blank-nick-fixture", "blank@example.invalid"}
	id, _, e := s.ResolveGoogle(identity, "Original")
	if e != nil {
		t.Fatal(e)
	}
	if _, e = s.db.Exec(`UPDATE accounts SET nickname='' WHERE id=?`, id); e != nil {
		t.Fatal(e)
	}
	again, created, e := s.ResolveGoogle(identity, "")
	if e != nil || created || again != id {
		t.Fatal("existing identity changed", e)
	}
	p, e := s.Profile(id)
	if e != nil || p.Nickname == "" || !p.NicknameIsDefault {
		t.Fatal(p, e)
	}
}
