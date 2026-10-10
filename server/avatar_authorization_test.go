package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"testing"
)

func publicIdentityFixture() map[string]any {
	return map[string]any{
		"device_id":            "owner-device",
		"agreement_public_key": base64.RawURLEncoding.EncodeToString(make([]byte, 32)),
		"signing_public_key":   base64.RawURLEncoding.EncodeToString(make([]byte, 32)),
	}
}

func TestAvatarKeyRegistrationRequiresExplicitAuthorization(t *testing.T) {
	s := newTestSocial(t)
	owner := registerTestUser(t, s, "consent-invite", "owner", "owner-device")
	ts := httptest.NewServer(SocialHandler(s))
	defer ts.Close()
	body := publicIdentityFixture()
	for _, consent := range []any{nil, false} {
		if consent != nil {
			body["authorize"] = consent
		}
		resp, out := avatarAPI(t, ts.Client(), "POST", ts.URL+"/v3/devices/keys", owner.AccessToken, newID("consent_"), body)
		if resp.StatusCode != 400 || out["code"] != "AVATAR_AUTHORIZATION_REQUIRED" {
			t.Fatalf("implicit key registration allowed: status=%d code=%v", resp.StatusCode, out["code"])
		}
	}
	var count int
	if err := s.db.QueryRow(`SELECT count(*) FROM device_keys`).Scan(&count); err != nil || count != 0 {
		t.Fatalf("unauthorized request saved keys: count=%d err=%v", count, err)
	}
	// Authorization works even when nobody else has enabled the feature.
	body["authorize"] = true
	resp, out := avatarAPI(t, ts.Client(), "POST", ts.URL+"/v3/devices/keys", owner.AccessToken, "consent-first", body)
	if resp.StatusCode != 201 {
		t.Fatalf("first independent authorization: %d code=%v", resp.StatusCode, out["code"])
	}
	firstVersion := out["key_version"]
	resp, out = avatarAPI(t, ts.Client(), "POST", ts.URL+"/v3/devices/keys", owner.AccessToken, "consent-restart", body)
	if resp.StatusCode != 201 || out["key_version"] != firstVersion {
		t.Fatalf("restoring the same long-term identity rotated it: status=%d version=%v want=%v", resp.StatusCode, out["key_version"], firstVersion)
	}
}

func TestAvatarAuthorizedFriendReadinessInSnapshot(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "a-consent", "alice", "alice-device")
	b := registerTestUser(t, s, "b-consent", "owner", "owner-device")
	c := registerTestUser(t, s, "c-consent", "carol", "carol-device")
	makeFriends(t, s, a, b)
	makeFriends(t, s, a, c)
	rt := NewSocialRuntime(s)
	if err := rt.Connect(a.AccountID, "alice-device", "test-session"); err != nil {
		t.Fatal(err)
	}
	readiness := func() map[string]bool {
		t.Helper()
		snapshot, err := rt.Snapshot(a.AccountID, "alice-device", "test-session", "snapshot")
		if err != nil {
			t.Fatal(err)
		}
		data, _ := json.Marshal(snapshot)
		var wire struct {
			Contacts []struct {
				ID    string `json:"account_id"`
				Ready bool   `json:"avatar_key_ready"`
			} `json:"contacts"`
		}
		if err := json.Unmarshal(data, &wire); err != nil {
			t.Fatal(err)
		}
		out := map[string]bool{}
		for _, contact := range wire.Contacts {
			out[contact.ID] = contact.Ready
		}
		return out
	}
	if r := readiness(); len(r) != 2 || r[b.AccountID] || r[c.AccountID] {
		t.Fatalf("new friends unexpectedly enabled: %v", r)
	}
	body := publicIdentityFixture()
	_, err := s.RegisterDeviceKeys(b.AccountID, "owner-device", body["agreement_public_key"].(string), body["signing_public_key"].(string))
	if err != nil {
		t.Fatal(err)
	}
	if r := readiness(); !r[b.AccountID] || r[c.AccountID] {
		t.Fatalf("authorized friend not discoverable while at home/offline: %v", r)
	}
}

func TestPreviouslyAutomaticKeysRequireNewAuthorization(t *testing.T) {
	s, owner, requester, _, envelope := avatarFixture(t)
	key, err := s.ActiveDeviceKey(owner.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	// Models an upgraded database: public keys exist, explicit consent does not.
	if _, err = s.db.Exec(`DELETE FROM avatar_authorizations WHERE account_id=?`, owner.AccountID); err != nil {
		t.Fatal(err)
	}
	if _, err = s.ActiveDeviceKey(owner.AccountID); !errors.Is(err, ErrAvatarNotEnabled) {
		t.Fatalf("legacy key became implicit authorization: %v", err)
	}
	if _, err = s.CreateAvatarTask(requester.AccountID, "requester-device", owner.AccountID, envelope); !errors.Is(err, ErrAvatarNotEnabled) {
		t.Fatalf("legacy owner accepted a question: %v", err)
	}
	confirmed, err := s.RegisterDeviceKeys(owner.AccountID, "owner-device", key.AgreementPublicKey, key.SigningPublicKey)
	if err != nil || confirmed.KeyVersion != key.KeyVersion {
		t.Fatalf("existing identity not reused after consent: version=%d err=%v", confirmed.KeyVersion, err)
	}
	policy, err := s.AvatarPolicy(owner.AccountID, requester.AccountID)
	if err != nil || policy.AllowAutoAsk {
		t.Fatalf("key consent enabled automatic answering: policy=%v err=%v", policy, err)
	}
}

func TestLongTermIdentityReregistrationPreservesReplayProtection(t *testing.T) {
	s, owner, requester, private, envelope := avatarFixture(t)
	if _, err := s.CreateAvatarTask(requester.AccountID, "requester-device", owner.AccountID, envelope); err != nil {
		t.Fatal(err)
	}
	key, err := s.ActiveDeviceKey(requester.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.RegisterDeviceKeys(requester.AccountID, "requester-device", key.AgreementPublicKey, key.SigningPublicKey); err != nil {
		t.Fatal(err)
	}
	envelope.TaskID = newID("dlg_")
	envelope.Signature = base64.RawURLEncoding.EncodeToString(ed25519.Sign(private, envelope.SignableBytes()))
	if _, err = s.CreateAvatarTask(requester.AccountID, "requester-device", owner.AccountID, envelope); !errors.Is(err, ErrAvatarProtocol) {
		t.Fatalf("reregistering accepted a reused sequence: %v", err)
	}
}

func TestSendingVisitorsHomeRevokesAvatarChannel(t *testing.T) {
	for _, all := range []bool{false, true} {
		t.Run(map[bool]string{false: "one", true: "all"}[all], func(t *testing.T) {
			s, rt, owner, requester, _, envelope := connectAvatarFixture(t)
			task, err := rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, envelope)
			if err != nil {
				t.Fatal(err)
			}
			if all {
				err = rt.SendAllHome(requester.AccountID)
			} else {
				err = rt.SendHome(requester.AccountID, owner.AccountID)
			}
			if err != nil {
				t.Fatal(err)
			}
			after, err := s.AvatarTask(task.ID)
			if err != nil || after.State != AvatarRevoked || rt.HasAvatarCiphertext(task.ID) {
				t.Fatalf("departed visitor retained active question: state=%s ciphertext=%v err=%v", after.State, rt.HasAvatarCiphertext(task.ID), err)
			}
			if err = rt.RespondAvatar(owner.AccountID, task.ID, true); err == nil {
				t.Fatal("departed visitor question could still be approved")
			}
		})
	}
}
