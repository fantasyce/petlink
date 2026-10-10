package main

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"strings"
	"sync"
	"testing"
)

func TestAvatarPolicyChangeRevokesInflightForEveryProvider(t *testing.T) {
	for _, provider := range []string{"claude", "codex", "deepseek", "owner_default"} {
		for _, state := range []string{AvatarPendingApproval, AvatarRouted, AvatarRunning, AvatarCompleted} {
			t.Run(provider+"/"+state, func(t *testing.T) {
				s, rt, owner, requester, key, envelope := connectAvatarFixture(t)
				policy, err := s.SetAvatarPolicy(owner.AccountID, requester.AccountID, AvatarPolicy{AllowAutoAsk: true, Provider: provider})
				if err != nil {
					t.Fatal(err)
				}
				envelope.PolicyRevision = policy.Revision
				envelope.Signature = base64.RawURLEncoding.EncodeToString(ed25519.Sign(key, envelope.SignableBytes()))
				task, err := rt.SubmitAvatar(requester.AccountID, "requester-device", owner.AccountID, envelope)
				if err != nil {
					t.Fatal(err)
				}
				if _, err = s.db.Exec(`UPDATE avatar_tasks SET state=? WHERE id=?`, state, task.ID); err != nil {
					t.Fatal(err)
				}
				if _, err = s.SetAvatarPolicy(owner.AccountID, requester.AccountID, AvatarPolicy{AllowAutoAsk: false, Provider: provider}); err != nil {
					t.Fatal(err)
				}
				got, err := s.AvatarTask(task.ID)
				if err != nil {
					t.Fatal(err)
				}
				if state == AvatarCompleted {
					if got.State != AvatarCompleted {
						t.Fatalf("completed task changed: %s", got.State)
					}
					return
				}
				if got.State != AvatarRevoked || got.ErrorCode != "AVATAR_TASK_REVOKED" {
					t.Fatalf("withdrawn request remains %s / %s", got.State, got.ErrorCode)
				}
				if err = s.CompleteAvatarTask(owner.AccountID, task.ID, strings.Repeat("a", 64)); !errors.Is(err, ErrAvatarTaskRevoked) {
					t.Fatalf("late result accepted: %v", err)
				}
				for _, who := range []struct{ account, device, session string }{{owner.AccountID, "owner-device", "owner-session"}, {requester.AccountID, "requester-device", "requester-session"}} {
					snapshot, err := rt.Snapshot(who.account, who.device, who.session, "policy-withdrawal")
					if err != nil || len(snapshot.AvatarTasks) != 1 || snapshot.AvatarTasks[0].Task.State != AvatarRevoked || snapshot.AvatarTasks[0].Request != nil || snapshot.AvatarTasks[0].Result != nil {
						t.Fatalf("revocation not projected safely: %v", err)
					}
				}
				if rt.HasAvatarCiphertext(task.ID) {
					t.Fatal("withdrawn request retained relay ciphertext")
				}
			})
		}
	}
}

func TestAvatarPolicyAndRevocationCommitTogether(t *testing.T) {
	s, _, owner, requester, _, envelope := connectAvatarFixture(t)
	if _, err := s.CreateAvatarTask(requester.AccountID, "requester-device", owner.AccountID, envelope); err != nil {
		t.Fatal(err)
	}
	if _, err := s.db.Exec(`CREATE TRIGGER reject_policy_revocation BEFORE UPDATE ON avatar_tasks BEGIN SELECT RAISE(ABORT,'test revocation storage failure'); END`); err != nil {
		t.Fatal(err)
	}
	if _, err := s.SetAvatarPolicy(owner.AccountID, requester.AccountID, AvatarPolicy{AllowAutoAsk: true, Provider: "codex"}); err == nil {
		t.Fatal("policy update succeeded despite failed revocation")
	}
	policy, err := s.AvatarPolicy(owner.AccountID, requester.AccountID)
	if err != nil || policy.Revision != 0 || policy.AllowAutoAsk || policy.Provider != "owner_default" {
		t.Fatalf("partial policy committed: %#v %v", policy, err)
	}
	task, err := s.AvatarTask(envelope.TaskID)
	if err != nil || task.State != AvatarPendingApproval || task.ErrorCode != "" {
		t.Fatalf("partial revocation committed: %#v %v", task, err)
	}
}

func TestAvatarPolicyWithdrawalIsScopedToOneDirectionAndContact(t *testing.T) {
	s, _, owner, requester, _, envelope := connectAvatarFixture(t)
	if _, err := s.CreateAvatarTask(requester.AccountID, "requester-device", owner.AccountID, envelope); err != nil {
		t.Fatal(err)
	}
	other := registerTestUser(t, s, "policy-other-invite", "policyother", "other-device")
	// Seed sibling task metadata to check the storage operation's scope. Their
	// cryptographic admission is covered separately by signed-envelope tests.
	for _, sibling := range []struct{ id, owner, peer string }{{"policy-reverse", requester.AccountID, owner.AccountID}, {"policy-other-contact", owner.AccountID, other.AccountID}} {
		_, err := s.db.Exec(`INSERT INTO avatar_tasks(id,owner_id,requester_id,requester_device_id,owner_device_id,provider,state,visit_revision,policy_revision,request_digest,created_at,expires_at) SELECT ?,?,?,requester_device_id,owner_device_id,provider,state,visit_revision,policy_revision,request_digest,created_at,expires_at FROM avatar_tasks WHERE id=?`, sibling.id, sibling.owner, sibling.peer, envelope.TaskID)
		if err != nil {
			t.Fatal(err)
		}
	}
	if _, err := s.SetAvatarPolicy(owner.AccountID, requester.AccountID, AvatarPolicy{Provider: "codex"}); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"policy-reverse", "policy-other-contact"} {
		task, err := s.AvatarTask(id)
		if err != nil || task.State != AvatarPendingApproval {
			t.Fatalf("unrelated task affected: %s %v", id, err)
		}
	}
}

func TestAvatarPolicyWithdrawalRacesTaskTransitions(t *testing.T) {
	for _, transition := range []string{"start", "complete"} {
		for i := 0; i < 6; i++ {
			t.Run(transition, func(t *testing.T) {
				s, _, owner, requester, _, envelope := connectAvatarFixture(t)
				if _, err := s.CreateAvatarTask(requester.AccountID, "requester-device", owner.AccountID, envelope); err != nil {
					t.Fatal(err)
				}
				if err := s.RespondAvatarTask(owner.AccountID, envelope.TaskID, true); err != nil {
					t.Fatal(err)
				}
				if transition == "complete" {
					if err := s.StartAvatarTask(owner.AccountID, envelope.TaskID); err != nil {
						t.Fatal(err)
					}
				}
				var wg sync.WaitGroup
				wg.Add(2)
				start := make(chan struct{})
				var policyErr, transitionErr error
				go func() {
					defer wg.Done()
					<-start
					_, policyErr = s.SetAvatarPolicy(owner.AccountID, requester.AccountID, AvatarPolicy{Provider: "owner_default"})
				}()
				go func() {
					defer wg.Done()
					<-start
					if transition == "start" {
						transitionErr = s.StartAvatarTask(owner.AccountID, envelope.TaskID)
					} else {
						transitionErr = s.CompleteAvatarTask(owner.AccountID, envelope.TaskID, strings.Repeat("a", 64))
					}
				}()
				close(start)
				wg.Wait()
				if policyErr != nil {
					t.Fatal(policyErr)
				}
				task, err := s.AvatarTask(envelope.TaskID)
				if err != nil {
					t.Fatal(err)
				}
				if transition == "complete" && transitionErr == nil {
					if task.State != AvatarCompleted {
						t.Fatalf("committed result changed: %s", task.State)
					}
				} else if task.State != AvatarRevoked {
					t.Fatalf("inflight task survived withdrawal: %s", task.State)
				}
				if err = s.CompleteAvatarTask(owner.AccountID, envelope.TaskID, strings.Repeat("b", 64)); err == nil {
					t.Fatal("late result advanced terminal task")
				}
			})
		}
	}
}
