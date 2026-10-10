package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"strings"
	"testing"
	"time"
)

func TestAvatarExpiryClearsBothViewsAndCiphertext(t *testing.T) {
	for _, state := range []string{AvatarPendingApproval, AvatarRouted, AvatarRunning} {
		t.Run(state, func(t *testing.T) {
			s, rt, owner, requester, _, envelope := connectAvatarFixture(t)
			created, err := rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, envelope)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = s.db.Exec(`UPDATE avatar_tasks SET state=?,expires_at=? WHERE id=?`, state, time.Now().Add(-time.Second).UnixMilli(), created.ID); err != nil {
				t.Fatal(err)
			}
			for _, who := range []struct{ account, device, session string }{{owner.AccountID, "owner-device", "owner-session"}, {requester.AccountID, "requester-device", "requester-session"}} {
				snapshot, err := rt.Snapshot(who.account, who.device, who.session, "expiry")
				if err != nil || len(snapshot.AvatarTasks) != 1 || snapshot.AvatarTasks[0].Task.State != AvatarExpired {
					t.Fatalf("expiry not visible: %#v %v", snapshot.AvatarTasks, err)
				}
			}
			if rt.HasAvatarCiphertext(created.ID) {
				t.Fatal("expired request retained ciphertext")
			}
			if s.RespondAvatarTask(owner.AccountID, created.ID, true) == nil || s.StartAvatarTask(owner.AccountID, created.ID) == nil || s.CompleteAvatarTask(owner.AccountID, created.ID, strings.Repeat("a", 64)) == nil {
				t.Fatal("expired task advanced")
			}
		})
	}
}

func TestAvatarLateCompletionCannotBeatExpirySweep(t *testing.T) {
	s, _, owner, _, _, envelope := connectAvatarFixture(t)
	if _, err := s.CreateAvatarTask(envelope.SenderAccountID, "requester-device", owner.AccountID, envelope); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`UPDATE avatar_tasks SET state='running',expires_at=? WHERE id=?`, time.Now().Add(-time.Second).UnixMilli(), envelope.TaskID); err != nil {
		t.Fatal(err)
	}
	if err := s.CompleteAvatarTask(owner.AccountID, envelope.TaskID, strings.Repeat("a", 64)); err == nil {
		t.Fatal("late completion accepted before sweep")
	}
}

func TestAvatarExpiredTaskReleasesCapacityWithoutSnapshot(t *testing.T) {
	s, rt, owner, requester, key, envelope := connectAvatarFixture(t)
	if _, err := rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, envelope); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`UPDATE avatar_tasks SET expires_at=? WHERE id=?`, time.Now().Add(-time.Second).UnixMilli(), envelope.TaskID); err != nil {
		t.Fatal(err)
	}
	oldID := envelope.TaskID
	envelope.TaskID = newID("dlg_")
	envelope.Sequence++
	envelope.Signature = base64.RawURLEncoding.EncodeToString(ed25519.Sign(key, envelope.SignableBytes()))
	if _, err := rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, envelope); err != nil {
		t.Fatalf("expired task blocked new question: %v", err)
	}
	if rt.HasAvatarCiphertext(oldID) {
		t.Fatal("old request retained")
	}
	if _, err := rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, envelope); err == nil {
		t.Fatal("duplicate question accepted")
	}
}

func connectAvatarFixture(t *testing.T) (*SocialStore, *SocialRuntime, AuthResult, AuthResult, ed25519.PrivateKey, AvatarEnvelope) {
	t.Helper()
	s, owner, requester, key, envelope := avatarFixture(t)
	rt := NewSocialRuntime(s)
	rt.readyAt = time.Time{}
	if err := rt.Connect(owner.AccountID, "owner-device", "owner-session"); err != nil {
		t.Fatal(err)
	}
	if err := rt.Connect(requester.AccountID, "requester-device", "requester-session"); err != nil {
		t.Fatal(err)
	}
	return s, rt, owner, requester, key, envelope
}

func TestAvatarRuntimeRoutesCiphertextOnlyToParticipants(t *testing.T) {
	_, rt, owner, requester, _, envelope := connectAvatarFixture(t)
	created, err := rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, envelope)
	if err != nil {
		t.Fatal(err)
	}
	ownerSnapshot, err := rt.Snapshot(owner.AccountID, "owner-device", "owner-session", "owner-sync")
	if err != nil {
		t.Fatal(err)
	}
	if len(ownerSnapshot.AvatarTasks) != 1 || ownerSnapshot.AvatarTasks[0].Task.ID != created.ID || ownerSnapshot.AvatarTasks[0].Request == nil || ownerSnapshot.AvatarTasks[0].Request.Ciphertext != envelope.Ciphertext {
		t.Fatalf("owner avatar tasks=%#v", ownerSnapshot.AvatarTasks)
	}
	requesterSnapshot, err := rt.Snapshot(requester.AccountID, "requester-device", "requester-session", "requester-sync")
	if err != nil {
		t.Fatal(err)
	}
	if len(requesterSnapshot.AvatarTasks) != 1 || requesterSnapshot.AvatarTasks[0].Request != nil {
		t.Fatalf("requester saw request envelope: %#v", requesterSnapshot.AvatarTasks)
	}
}

func TestAvatarRuntimeRejectionVisibleAndCannotStart(t *testing.T) {
	_, rt, owner, requester, _, envelope := connectAvatarFixture(t)
	created, err := rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, envelope)
	if err != nil {
		t.Fatal(err)
	}
	if err = rt.RespondAvatar(owner.AccountID, created.ID, false); err != nil {
		t.Fatal(err)
	}
	snapshot, err := rt.Snapshot(requester.AccountID, "requester-device", "requester-session", "rejected-sync")
	if err != nil {
		t.Fatal(err)
	}
	if len(snapshot.AvatarTasks) != 1 || snapshot.AvatarTasks[0].Task.State != AvatarRejected {
		t.Fatal("requester did not receive rejection")
	}
	if snapshot.AvatarTasks[0].Request != nil || snapshot.AvatarTasks[0].Result != nil || rt.HasAvatarCiphertext(created.ID) {
		t.Fatal("rejected task retained ciphertext")
	}
	if err = rt.StartAvatar(owner.AccountID, created.ID); err == nil {
		t.Fatal("rejected task started")
	}
}

func TestAvatarRuntimeCompletesWithEncryptedResultAndRejectsLateResult(t *testing.T) {
	s, rt, owner, requester, ownerSigning, request := connectAvatarFixture(t)
	created, err := rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, request)
	if err != nil {
		t.Fatal(err)
	}
	if err = rt.RespondAvatar(owner.AccountID, created.ID, true); err != nil {
		t.Fatal(err)
	}
	if err = rt.StartAvatar(owner.AccountID, created.ID); err != nil {
		t.Fatal(err)
	}
	result := request
	result.SenderAccountID = owner.AccountID
	result.SenderDeviceID = "owner-device"
	result.RecipientAccountID = requester.AccountID
	result.RecipientDeviceID = "requester-device"
	result.Ciphertext = base64.RawURLEncoding.EncodeToString([]byte("encrypted-answer"))
	result.Signature = base64.RawURLEncoding.EncodeToString(ed25519.Sign(ownerSigning, result.SignableBytes()))
	// The fixture owner key is intentionally not the request signing key. Register
	// the matching result signing key before completion.
	var agreement string
	_ = s.db.QueryRow(`SELECT agreement_public_key FROM device_keys WHERE account_id=? AND revoked_at IS NULL`, owner.AccountID).Scan(&agreement)
	_, _ = s.RegisterDeviceKeys(owner.AccountID, "owner-device", agreement, base64.RawURLEncoding.EncodeToString(ownerSigning.Public().(ed25519.PublicKey)))
	if err = rt.CompleteAvatar(owner.AccountID, created.ID, result); err != nil {
		t.Fatal(err)
	}
	snapshot, err := rt.Snapshot(requester.AccountID, "requester-device", "requester-session", "result-sync")
	if err != nil || len(snapshot.AvatarTasks) != 1 || snapshot.AvatarTasks[0].Result == nil || snapshot.AvatarTasks[0].Result.Ciphertext != result.Ciphertext {
		t.Fatalf("snapshot=%#v err=%v", snapshot.AvatarTasks, err)
	}
	if err = rt.CompleteAvatar(owner.AccountID, created.ID, result); err == nil {
		t.Fatal("late duplicate result accepted")
	}
}

func TestAvatarRuntimeRecallRevokesTaskAndDropsCiphertext(t *testing.T) {
	_, rt, owner, requester, _, envelope := connectAvatarFixture(t)
	created, err := rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, envelope)
	if err != nil {
		t.Fatal(err)
	}
	if err = rt.Recall(owner.AccountID); err != nil {
		t.Fatal(err)
	}
	task, err := rt.store.AvatarTask(created.ID)
	if err != nil || task.State != AvatarRevoked {
		t.Fatalf("task=%#v err=%v", task, err)
	}
	if rt.HasAvatarCiphertext(created.ID) {
		t.Fatal("revoked task retained ciphertext")
	}
}

func TestAvatarRuntimeDisconnectRevokesTaskAndDropsCiphertext(t *testing.T) {
	_, rt, owner, requester, _, envelope := connectAvatarFixture(t)
	created, err := rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, envelope)
	if err != nil {
		t.Fatal(err)
	}
	rt.Disconnect(owner.AccountID, "owner-session")
	task, err := rt.store.AvatarTask(created.ID)
	if err != nil || task.State != AvatarRevoked {
		t.Fatalf("task=%#v err=%v", task, err)
	}
	if rt.HasAvatarCiphertext(created.ID) {
		t.Fatal("disconnect retained ciphertext")
	}
}
