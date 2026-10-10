package main

import (
	"database/sql"
	"errors"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

func newTestSocial(t *testing.T) *SocialStore {
	t.Helper()
	s, err := OpenSocialStore(filepath.Join(t.TempDir(), "social.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func TestSimultaneousFriendRequestsCreateOnlyOnePendingRequest(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "invite-a", "alice", "mac-a")
	b := registerTestUser(t, s, "invite-b", "bob", "mac-b")
	start := make(chan struct{})
	errs := make(chan error, 2)
	var wg sync.WaitGroup
	for _, pair := range [][2]string{{a.AccountID, b.FriendID}, {b.AccountID, a.FriendID}} {
		wg.Add(1)
		go func(from, friendID string) {
			defer wg.Done()
			<-start
			_, err := s.RequestFriend(from, friendID)
			errs <- err
		}(pair[0], pair[1])
	}
	close(start)
	wg.Wait()
	close(errs)
	success, duplicate := 0, 0
	for err := range errs {
		switch {
		case err == nil:
			success++
		case errors.Is(err, ErrRequestExists):
			duplicate++
		default:
			t.Fatalf("unexpected error: %v", err)
		}
	}
	var count int
	_ = s.db.QueryRow(`SELECT count(*) FROM friend_requests WHERE status='pending'`).Scan(&count)
	if success != 1 || duplicate != 1 || count != 1 {
		t.Fatalf("success=%d duplicate=%d pending=%d", success, duplicate, count)
	}
}

func registerTestUser(t *testing.T, s *SocialStore, invite, user, device string) AuthResult {
	t.Helper()
	if err := s.CreateInvite(invite, time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	r, err := s.Register(RegisterInput{Invite: invite, Username: user, Password: "correct horse battery staple", Nickname: user, DeviceID: device})
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestRegisterConsumesInviteAndHashesPassword(t *testing.T) {
	s := newTestSocial(t)
	r := registerTestUser(t, s, "invite-a", "alice", "mac-a")
	if r.FriendID == "" || r.AccessToken == "" || r.RefreshToken == "" || r.RecoveryCode == "" {
		t.Fatalf("incomplete auth result: %#v", r)
	}
	if _, err := s.Register(RegisterInput{Invite: "invite-a", Username: "alice2", Password: "another secure password", Nickname: "Alice", DeviceID: "mac-x"}); !errors.Is(err, ErrInviteInvalid) {
		t.Fatalf("invite reuse: %v", err)
	}
	var passwordHash, accessHash string
	if err := s.db.QueryRow(`SELECT password_hash FROM accounts WHERE id=?`, r.AccountID).Scan(&passwordHash); err != nil {
		t.Fatal(err)
	}
	if err := s.db.QueryRow(`SELECT access_hash FROM sessions WHERE account_id=?`, r.AccountID).Scan(&accessHash); err != nil {
		t.Fatal(err)
	}
	if passwordHash == "correct horse battery staple" || accessHash == r.AccessToken {
		t.Fatal("plaintext credential persisted")
	}
}

func TestDuplicateUsernameReturnsStableErrorWithoutConsumingInvite(t *testing.T) {
	s := newTestSocial(t)
	_ = registerTestUser(t, s, "invite-a", "alice", "mac-a")
	if err := s.CreateInvite("invite-b", time.Now().Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	_, err := s.Register(RegisterInput{Invite: "invite-b", Username: "Alice", Password: "another secure password", Nickname: "Other", DeviceID: "mac-b"})
	if !errors.Is(err, ErrUsernameTaken) {
		t.Fatalf("duplicate username error=%v", err)
	}
	var used sql.NullInt64
	if err = s.db.QueryRow(`SELECT used_at FROM invites WHERE code_hash=?`, hashValue("invite-b")).Scan(&used); err != nil || used.Valid {
		t.Fatalf("duplicate username consumed invite: used=%v err=%v", used, err)
	}
}

func TestLoginRequiresTakeoverForAnotherDevice(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "invite-a", "alice", "mac-a")
	if _, err := s.Login(LoginInput{Username: "alice", Password: "wrong password", DeviceID: "mac-a"}); !errors.Is(err, ErrLoginFailed) {
		t.Fatalf("wrong password: %v", err)
	}
	if _, err := s.Login(LoginInput{Username: "alice", Password: "correct horse battery staple", DeviceID: "mac-b"}); !errors.Is(err, ErrTakeoverRequired) {
		t.Fatalf("new device login: %v", err)
	}
	r, err := s.Takeover(TakeoverInput{Username: "alice", Password: "correct horse battery staple", DeviceID: "mac-b"})
	if err != nil {
		t.Fatal(err)
	}
	if r.AccountID != a.AccountID {
		t.Fatal("takeover changed account")
	}
	if _, err := s.AuthAccess(a.AccessToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("old access still valid: %v", err)
	}
}

func TestFriendRequestAcceptAndBlock(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "invite-a", "alice", "mac-a")
	b := registerTestUser(t, s, "invite-b", "bob", "mac-b")
	req, err := s.RequestFriend(a.AccountID, b.FriendID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.RequestFriend(a.AccountID, b.FriendID); !errors.Is(err, ErrRequestExists) {
		t.Fatalf("duplicate request: %v", err)
	}
	if err = s.RespondFriend(b.AccountID, req.ID, true); err != nil {
		t.Fatal(err)
	}
	contacts, err := s.Contacts(a.AccountID)
	if err != nil || len(contacts) != 1 || contacts[0].AccountID != b.AccountID {
		t.Fatalf("contacts=%#v err=%v", contacts, err)
	}
	if err = s.Block(a.AccountID, b.AccountID); err != nil {
		t.Fatal(err)
	}
	if _, err = s.RequestFriend(b.AccountID, a.FriendID); !errors.Is(err, ErrBlocked) {
		t.Fatalf("blocked request: %v", err)
	}
}

func TestFriendAndVisitRejectionAndExpiry(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "invite-a", "alice", "mac-a")
	b := registerTestUser(t, s, "invite-b", "bob", "mac-b")
	rejected, e := s.RequestFriend(a.AccountID, b.FriendID)
	if e != nil {
		t.Fatal(e)
	}
	if e = s.RespondFriend(b.AccountID, rejected.ID, false); e != nil {
		t.Fatal(e)
	}
	if e = s.RespondFriend(b.AccountID, rejected.ID, true); !errors.Is(e, ErrRequestExpired) {
		t.Fatalf("friend replay=%v", e)
	}
	expired, e := s.RequestFriend(a.AccountID, b.FriendID)
	if e != nil {
		t.Fatal(e)
	}
	_, _ = s.db.Exec(`UPDATE friend_requests SET expires_at=? WHERE id=?`, time.Now().Add(-time.Second).UnixMilli(), expired.ID)
	if e = s.RespondFriend(b.AccountID, expired.ID, true); !errors.Is(e, ErrRequestExpired) {
		t.Fatalf("friend expiry=%v", e)
	}
	makeFriends(t, s, a, b)
	visitRejected, e := s.RequestVisit(a.AccountID, b.AccountID)
	if e != nil {
		t.Fatal(e)
	}
	if e = s.RespondVisit(b.AccountID, visitRejected.ID, false); e != nil {
		t.Fatal(e)
	}
	if e = s.RespondVisit(b.AccountID, visitRejected.ID, true); !errors.Is(e, ErrRequestExpired) {
		t.Fatalf("visit replay=%v", e)
	}
	visit, e := s.RequestVisit(a.AccountID, b.AccountID)
	if e != nil {
		t.Fatal(e)
	}
	_, _ = s.db.Exec(`UPDATE visit_requests SET expires_at=? WHERE id=?`, time.Now().Add(-time.Second).UnixMilli(), visit.ID)
	if e = s.RespondVisit(b.AccountID, visit.ID, true); !errors.Is(e, ErrRequestExpired) {
		t.Fatalf("visit expiry=%v", e)
	}
}

func TestVisitApprovalPrivateAutoAndCapacity(t *testing.T) {
	s := newTestSocial(t)
	host := registerTestUser(t, s, "invite-host", "host", "host-mac")
	guests := make([]AuthResult, 4)
	for i, name := range []string{"one", "two", "three", "four"} {
		guests[i] = registerTestUser(t, s, "invite-"+name, name, "mac-"+name)
		r, err := s.RequestFriend(guests[i].AccountID, host.FriendID)
		if err != nil {
			t.Fatal(err)
		}
		if err = s.RespondFriend(host.AccountID, r.ID, true); err != nil {
			t.Fatal(err)
		}
	}
	request, err := s.RequestVisit(guests[0].AccountID, host.AccountID)
	if err != nil || request.Status != "pending" {
		t.Fatalf("ordinary visit=%#v err=%v", request, err)
	}
	if err = s.RespondVisit(host.AccountID, request.ID, true); err != nil {
		t.Fatal(err)
	}
	if err = s.SetContactPolicy(host.AccountID, guests[1].AccountID, ContactPolicy{Trusted: true}); err != nil {
		t.Fatal(err)
	}
	auto, err := s.RequestVisit(guests[1].AccountID, host.AccountID)
	if err != nil || auto.Status != "accepted" {
		t.Fatalf("trusted visit=%#v err=%v", auto, err)
	}
	third, err := s.RequestVisit(guests[2].AccountID, host.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.RespondVisit(host.AccountID, third.ID, true); err != nil {
		t.Fatal(err)
	}
	fourth, err := s.RequestVisit(guests[3].AccountID, host.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.RespondVisit(host.AccountID, fourth.ID, true); !errors.Is(err, ErrHostFull) {
		t.Fatalf("fourth visitor: %v", err)
	}
}

func TestAgentStatusIsPrivateUnlessShared(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "invite-a", "alice", "mac-a")
	b := registerTestUser(t, s, "invite-b", "bob", "mac-b")
	r, _ := s.RequestFriend(a.AccountID, b.FriendID)
	_ = s.RespondFriend(b.AccountID, r.ID, true)
	if err := s.UpdateAgentStatus(a.AccountID, AgentStatus{Provider: "codex", SessionRef: "opaque", State: "working", Sequence: 1, ExpiresAt: time.Now().Add(time.Minute)}); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.AgentStatusFor(b.AccountID, a.AccountID); got != nil {
		t.Fatalf("private status leaked: %#v", got)
	}
	if err := s.SetContactPolicy(a.AccountID, b.AccountID, ContactPolicy{ShareAgent: true}); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.AgentStatusFor(b.AccountID, a.AccountID); got == nil || got.State != "working" {
		t.Fatalf("shared status missing: %#v", got)
	}
	if err := s.SetContactPolicy(a.AccountID, b.AccountID, ContactPolicy{ShareAgent: false}); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.AgentStatusFor(b.AccountID, a.AccountID); got != nil {
		t.Fatalf("disabled share still visible: %#v", got)
	}
}

func TestAgentStatusAllowsExplicitSessionSwitchButRejectsReplay(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "invite-a", "alice", "mac-a")
	first := AgentStatus{Provider: "claude", SessionRef: "session-one", State: "working", Sequence: 50, ExpiresAt: time.Now().Add(time.Minute)}
	if err := s.UpdateAgentStatus(a.AccountID, first); err != nil {
		t.Fatal(err)
	}
	if err := s.UpdateAgentStatus(a.AccountID, first); !errors.Is(err, ErrValidation) {
		t.Fatalf("same-session replay accepted: %v", err)
	}
	switched := AgentStatus{Provider: "codex", SessionRef: "session-two", State: "idle", Sequence: 1, ExpiresAt: time.Now().Add(time.Minute)}
	if err := s.UpdateAgentStatus(a.AccountID, switched); err != nil {
		t.Fatalf("explicit session switch rejected: %v", err)
	}
	expired := AgentStatus{Provider: "codex", SessionRef: "session-two", State: "working", Sequence: 90, ExpiresAt: time.Now().Add(-time.Second)}
	s.mu.Lock()
	s.agent[a.AccountID] = expired
	s.mu.Unlock()
	restarted := AgentStatus{Provider: "codex", SessionRef: "session-two", State: "idle", Sequence: 1, ExpiresAt: time.Now().Add(time.Minute)}
	if err := s.UpdateAgentStatus(a.AccountID, restarted); err != nil {
		t.Fatalf("expired session blocked restarted sequence: %v", err)
	}
}

func TestRefreshRotatesTokenAndRecoveryIsSingleUse(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "invite-a", "alice", "mac-a")
	r, err := s.Refresh(a.RefreshToken)
	if err != nil {
		t.Fatal(err)
	}
	if r.RefreshToken == a.RefreshToken {
		t.Fatal("refresh token was not rotated")
	}
	if _, err = s.Refresh(a.RefreshToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("old refresh accepted: %v", err)
	}
	recovered, err := s.Recover(RecoverInput{Username: "alice", RecoveryCode: a.RecoveryCode, NewPassword: "a newly secured password", DeviceID: "mac-a"})
	if err != nil || recovered.RecoveryCode == "" {
		t.Fatalf("recover=%#v err=%v", recovered, err)
	}
	if _, err = s.Recover(RecoverInput{Username: "alice", RecoveryCode: a.RecoveryCode, NewPassword: "another secure password", DeviceID: "mac-a"}); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("recovery replay: %v", err)
	}
	if _, err = s.Refresh(r.RefreshToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("pre-recovery session survived: %v", err)
	}
	if err = s.Logout(recovered.AccessToken); err != nil {
		t.Fatal(err)
	}
	if _, err = s.AuthAccess(recovered.AccessToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("logout token valid: %v", err)
	}
}

func TestRequestListsCancelAndRelationshipRemovalReturnPet(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "ia", "alice", "mac-a")
	b := registerTestUser(t, s, "ib", "bob", "mac-b")
	fr, e := s.RequestFriend(a.AccountID, b.FriendID)
	if e != nil {
		t.Fatal(e)
	}
	incoming, e := s.PendingFriendRequests(b.AccountID)
	if e != nil || len(incoming) != 1 || incoming[0].ID != fr.ID {
		t.Fatalf("friend requests=%#v err=%v", incoming, e)
	}
	if e = s.RespondFriend(b.AccountID, fr.ID, true); e != nil {
		t.Fatal(e)
	}
	visit, e := s.RequestVisit(a.AccountID, b.AccountID)
	if e != nil {
		t.Fatal(e)
	}
	visits, e := s.PendingVisitRequests(b.AccountID)
	if e != nil || len(visits) != 1 || visits[0].ID != visit.ID {
		t.Fatalf("visits=%#v err=%v", visits, e)
	}
	if e = s.CancelVisit(a.AccountID, visit.ID); e != nil {
		t.Fatal(e)
	}
	if e = s.SetContactPolicy(b.AccountID, a.AccountID, ContactPolicy{Trusted: true}); e != nil {
		t.Fatal(e)
	}
	if _, e = s.RequestVisit(a.AccountID, b.AccountID); e != nil {
		t.Fatal(e)
	}
	if e = s.Block(b.AccountID, a.AccountID); e != nil {
		t.Fatal(e)
	}
	var target, phase string
	if e = s.db.QueryRow(`SELECT target_id,phase FROM pets WHERE owner_id=?`, a.AccountID).Scan(&target, &phase); e != nil {
		t.Fatal(e)
	}
	if target != a.AccountID || phase != "travel" {
		t.Fatalf("pet target=%s phase=%s", target, phase)
	}
}

func TestRevokingTrustedPolicySendsVisitorHome(t *testing.T) {
	s := newTestSocial(t)
	guest := registerTestUser(t, s, "ig", "guest", "mac-g")
	host := registerTestUser(t, s, "ih", "host", "mac-h")
	makeFriends(t, s, guest, host)
	if e := s.SetContactPolicy(host.AccountID, guest.AccountID, ContactPolicy{Trusted: true}); e != nil {
		t.Fatal(e)
	}
	if _, e := s.RequestVisit(guest.AccountID, host.AccountID); e != nil {
		t.Fatal(e)
	}
	if e := s.SetContactPolicy(host.AccountID, guest.AccountID, ContactPolicy{Trusted: false}); e != nil {
		t.Fatal(e)
	}
	var target, phase string
	if e := s.db.QueryRow(`SELECT target_id,phase FROM pets WHERE owner_id=?`, guest.AccountID).Scan(&target, &phase); e != nil {
		t.Fatal(e)
	}
	if target != guest.AccountID || phase != "travel" {
		t.Fatalf("target=%q phase=%q", target, phase)
	}
}

func TestUpdatingOrdinaryContactPolicyDoesNotSendApprovedVisitorHome(t *testing.T) {
	s := newTestSocial(t)
	guest := registerTestUser(t, s, "ig", "guest", "mac-g")
	host := registerTestUser(t, s, "ih", "host", "mac-h")
	makeFriends(t, s, guest, host)
	visit, e := s.RequestVisit(guest.AccountID, host.AccountID)
	if e != nil {
		t.Fatal(e)
	}
	if e = s.RespondVisit(host.AccountID, visit.ID, true); e != nil {
		t.Fatal(e)
	}
	if e = s.SetContactPolicy(host.AccountID, guest.AccountID, ContactPolicy{Trusted: false, ShareAgent: true, Note: "friend"}); e != nil {
		t.Fatal(e)
	}
	var target, phase, status string
	_ = s.db.QueryRow(`SELECT target_id,phase FROM pets WHERE owner_id=?`, guest.AccountID).Scan(&target, &phase)
	_ = s.db.QueryRow(`SELECT status FROM visit_requests WHERE id=?`, visit.ID).Scan(&status)
	if target != host.AccountID || phase != "travel" || status != "accepted" {
		t.Fatalf("ordinary visit changed: target=%q phase=%q status=%q", target, phase, status)
	}
}
