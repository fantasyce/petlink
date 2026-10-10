package main

import "testing"

func TestPrivateContactNotesDoNotChangeFriendNickname(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "note-invite-a", "note-a", "note-device-a")
	b := registerTestUser(t, s, "note-invite-b", "note-b", "note-device-b")
	makeFriends(t, s, a, b)
	profile, err := s.Profile(b.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.SetContactPolicy(a.AccountID, b.AccountID, ContactPolicy{Note: "阿青"}); err != nil {
		t.Fatal(err)
	}
	first, err := s.Contacts(a.AccountID)
	if err != nil || len(first) != 1 || first[0].Note != "阿青" || first[0].Nickname != profile.Nickname {
		t.Fatal("own note must preserve the friend's nickname", err)
	}
	reverse, err := s.Contacts(b.AccountID)
	if err != nil || len(reverse) != 1 || reverse[0].Note != "" {
		t.Fatal("friend must not receive the owner's private note", err)
	}
	if err = s.SetContactPolicy(b.AccountID, a.AccountID, ContactPolicy{Note: "另一份备注"}); err != nil {
		t.Fatal(err)
	}
	first, err = s.Contacts(a.AccountID)
	if err != nil || first[0].Note != "阿青" {
		t.Fatal("notes must be independent for each owner", err)
	}
	if err = s.SetContactPolicy(a.AccountID, b.AccountID, ContactPolicy{}); err != nil {
		t.Fatal(err)
	}
	first, err = s.Contacts(a.AccountID)
	if err != nil || first[0].Note != "" || first[0].Nickname != profile.Nickname {
		t.Fatal("clearing a note must leave the original nickname available", err)
	}
}
