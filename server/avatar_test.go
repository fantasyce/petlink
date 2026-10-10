package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
	"time"
)

func avatarFixture(t *testing.T) (*SocialStore, AuthResult, AuthResult, ed25519.PrivateKey, AvatarEnvelope) {
	t.Helper()
	s := newTestSocial(t)
	owner := registerTestUser(t, s, "owner-invite", "owner", "owner-device")
	requester := registerTestUser(t, s, "requester-invite", "requester", "requester-device")
	makeFriends(t, s, owner, requester)
	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	publicKey := privateKey.Public().(ed25519.PublicKey)
	agreement := make([]byte, 32)
	if _, err = rand.Read(agreement); err != nil {
		t.Fatal(err)
	}
	if _, err = s.RegisterDeviceKeys(requester.AccountID, "requester-device", base64.RawURLEncoding.EncodeToString(agreement), base64.RawURLEncoding.EncodeToString(publicKey)); err != nil {
		t.Fatal(err)
	}
	ownerAgreement := make([]byte, 32)
	ownerSigning := make([]byte, ed25519.PublicKeySize)
	_, _ = rand.Read(ownerAgreement)
	_, _ = rand.Read(ownerSigning)
	if _, err = s.RegisterDeviceKeys(owner.AccountID, "owner-device", base64.RawURLEncoding.EncodeToString(ownerAgreement), base64.RawURLEncoding.EncodeToString(ownerSigning)); err != nil {
		t.Fatal(err)
	}
	var revision int64
	if err = s.db.QueryRow(`SELECT revision FROM pets WHERE owner_id=?`, owner.AccountID).Scan(&revision); err != nil {
		t.Fatal(err)
	}
	if _, err = s.db.Exec(`UPDATE pets SET location_id=?,target_id='',phase='visit',revision=revision+1 WHERE owner_id=?`, requester.AccountID, owner.AccountID); err != nil {
		t.Fatal(err)
	}
	revision++
	now := time.Now().UTC()
	envelope := AvatarEnvelope{
		Version: 1, TaskID: newID("dlg_"), SenderAccountID: requester.AccountID,
		SenderDeviceID: "requester-device", RecipientAccountID: owner.AccountID,
		RecipientDeviceID: "owner-device", VisitRevision: revision, PolicyRevision: 0,
		Sequence: 1, CreatedAt: now, ExpiresAt: now.Add(time.Minute),
		EphemeralPublicKey: base64.RawURLEncoding.EncodeToString(agreement),
		Nonce:              base64.RawURLEncoding.EncodeToString(make([]byte, 12)),
		Ciphertext:         base64.RawURLEncoding.EncodeToString([]byte("encrypted-question")),
	}
	envelope.Signature = base64.RawURLEncoding.EncodeToString(ed25519.Sign(privateKey, envelope.SignableBytes()))
	return s, owner, requester, privateKey, envelope
}

func TestAvatarPolicyIsIndependentFromPrivateFriend(t *testing.T) {
	s, owner, requester, _, _ := avatarFixture(t)
	if err := s.SetContactPolicy(owner.AccountID, requester.AccountID, ContactPolicy{Trusted: true, ShareAgent: true}); err != nil {
		t.Fatal(err)
	}
	policy, err := s.AvatarPolicy(owner.AccountID, requester.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	if policy.AllowAutoAsk || policy.Provider != "owner_default" || policy.Revision != 0 {
		t.Fatalf("private friend inherited avatar permission: %#v", policy)
	}
	updated, err := s.SetAvatarPolicy(owner.AccountID, requester.AccountID, AvatarPolicy{AllowAutoAsk: true, Provider: "claude"})
	if err != nil || !updated.AllowAutoAsk || updated.Provider != "claude" || updated.Revision != 1 {
		t.Fatalf("updated=%#v err=%v", updated, err)
	}
}

func TestAvatarEnvelopeRejectsTamperReplayAndWrongDevice(t *testing.T) {
	s, owner, requester, privateKey, envelope := avatarFixture(t)
	if _, err := s.CreateAvatarTask(requester.AccountID, "wrong-device", owner.AccountID, envelope); !errors.Is(err, ErrAvatarProtocol) {
		t.Fatalf("wrong device err=%v", err)
	}
	tampered := envelope
	tampered.Ciphertext = base64.RawURLEncoding.EncodeToString([]byte("tampered"))
	if _, err := s.CreateAvatarTask(requester.AccountID, "requester-device", owner.AccountID, tampered); !errors.Is(err, ErrAvatarProtocol) {
		t.Fatalf("tamper err=%v", err)
	}
	envelope.Signature = base64.RawURLEncoding.EncodeToString(ed25519.Sign(privateKey, envelope.SignableBytes()))
	created, err := s.CreateAvatarTask(requester.AccountID, "requester-device", owner.AccountID, envelope)
	if err != nil || created.State != AvatarPendingApproval {
		t.Fatalf("created=%#v err=%v", created, err)
	}
	replay := envelope
	replay.TaskID = newID("dlg_")
	replay.Signature = base64.RawURLEncoding.EncodeToString(ed25519.Sign(privateKey, replay.SignableBytes()))
	if _, err = s.CreateAvatarTask(requester.AccountID, "requester-device", owner.AccountID, replay); !errors.Is(err, ErrAvatarProtocol) {
		t.Fatalf("sequence replay err=%v", err)
	}
}

func TestAvatarTaskRequiresCurrentVisitAndUsesExplicitAutoAsk(t *testing.T) {
	s, owner, requester, privateKey, envelope := avatarFixture(t)
	if _, err := s.SetAvatarPolicy(owner.AccountID, requester.AccountID, AvatarPolicy{AllowAutoAsk: true, Provider: "claude"}); err != nil {
		t.Fatal(err)
	}
	envelope.PolicyRevision = 1
	envelope.Signature = base64.RawURLEncoding.EncodeToString(ed25519.Sign(privateKey, envelope.SignableBytes()))
	created, err := s.CreateAvatarTask(requester.AccountID, "requester-device", owner.AccountID, envelope)
	if err != nil || created.State != AvatarRouted || created.Provider != "claude" {
		t.Fatalf("created=%#v err=%v", created, err)
	}
	second := envelope
	second.TaskID = newID("dlg_")
	second.Sequence++
	second.Signature = base64.RawURLEncoding.EncodeToString(ed25519.Sign(privateKey, second.SignableBytes()))
	if _, err = s.CreateAvatarTask(requester.AccountID, "requester-device", owner.AccountID, second); !errors.Is(err, ErrAvatarBusy) {
		t.Fatalf("second active task err=%v", err)
	}
	if _, err = s.db.Exec(`UPDATE avatar_tasks SET state='completed',finished_at=? WHERE id=?`, time.Now().UnixMilli(), created.ID); err != nil {
		t.Fatal(err)
	}
	if _, err = s.db.Exec(`UPDATE pets SET location_id=owner_id,phase='home',revision=revision+1 WHERE owner_id=?`, owner.AccountID); err != nil {
		t.Fatal(err)
	}
	third := second
	third.TaskID = newID("dlg_")
	third.Sequence++
	third.VisitRevision++
	third.Signature = base64.RawURLEncoding.EncodeToString(ed25519.Sign(privateKey, third.SignableBytes()))
	if _, err = s.CreateAvatarTask(requester.AccountID, "requester-device", owner.AccountID, third); !errors.Is(err, ErrAvatarPetNotPresent) {
		t.Fatalf("absent pet err=%v", err)
	}
}

func TestAvatarTaskTerminalStateIsImmutableAndRevocationCancelsActive(t *testing.T) {
	s, owner, requester, privateKey, envelope := avatarFixture(t)
	created, err := s.CreateAvatarTask(requester.AccountID, "requester-device", owner.AccountID, envelope)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.RespondAvatarTask(owner.AccountID, created.ID, true); err != nil {
		t.Fatal(err)
	}
	if err = s.StartAvatarTask(owner.AccountID, created.ID); err != nil {
		t.Fatal(err)
	}
	if err = s.RevokeAvatarTasks(owner.AccountID, "AVATAR_TASK_REVOKED"); err != nil {
		t.Fatal(err)
	}
	got, err := s.AvatarTask(created.ID)
	if err != nil || got.State != AvatarRevoked || got.ErrorCode != "AVATAR_TASK_REVOKED" {
		t.Fatalf("got=%#v err=%v", got, err)
	}
	if err = s.CompleteAvatarTask(owner.AccountID, created.ID, strings.Repeat("a", 64)); !errors.Is(err, ErrAvatarTaskRevoked) {
		t.Fatalf("late completion err=%v", err)
	}
	_ = privateKey
}

func TestAvatarAutoAskRateLimitIsThreePerTenMinutes(t *testing.T) {
	s, owner, requester, privateKey, envelope := avatarFixture(t)
	if _, err := s.SetAvatarPolicy(owner.AccountID, requester.AccountID, AvatarPolicy{AllowAutoAsk: true, Provider: "claude"}); err != nil {
		t.Fatal(err)
	}
	for i := int64(1); i <= 4; i++ {
		envelope.TaskID = newID("dlg_")
		envelope.Sequence = i
		envelope.PolicyRevision = 1
		envelope.CreatedAt = time.Now().UTC()
		envelope.ExpiresAt = envelope.CreatedAt.Add(time.Minute)
		envelope.Signature = base64.RawURLEncoding.EncodeToString(ed25519.Sign(privateKey, envelope.SignableBytes()))
		created, err := s.CreateAvatarTask(requester.AccountID, "requester-device", owner.AccountID, envelope)
		if i == 4 {
			if !errors.Is(err, ErrAvatarRateLimited) {
				t.Fatalf("fourth request err=%v", err)
			}
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if _, err = s.db.Exec(`UPDATE avatar_tasks SET state='completed',finished_at=? WHERE id=?`, time.Now().UnixMilli(), created.ID); err != nil {
			t.Fatal(err)
		}
	}
}
