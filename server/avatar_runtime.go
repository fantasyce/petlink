package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"time"
)

// Called with r.mu held, before projecting state or accepting task mutations.
func (r *SocialRuntime) expireAvatarTasks() error {
	now := r.now()
	rows, err := r.store.db.Query(`UPDATE avatar_tasks SET state='expired',error_code='AVATAR_TASK_EXPIRED',finished_at=? WHERE state IN ('pending_approval','routed','running') AND expires_at<=? RETURNING id`, now.UnixMilli(), now.UnixMilli())
	if err != nil {
		return err
	}
	for rows.Next() {
		var id string
		if err = rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		delete(r.avatar, id)
	}
	err = rows.Err()
	rows.Close()
	if err != nil {
		return err
	}
	for id, relay := range r.avatar {
		if !relay.ExpiresAt.After(now) {
			delete(r.avatar, id)
		}
	}
	return nil
}

func (r *SocialRuntime) SubmitAvatar(requester, device, owner string, envelope AvatarEnvelope) (AvatarTaskRecord, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.expireAvatarTasks(); err != nil {
		return AvatarTaskRecord{}, err
	}
	if !r.online(requester) || !r.online(owner) {
		return AvatarTaskRecord{}, errors.New("PEER_OFFLINE")
	}
	task, err := r.store.CreateAvatarTask(requester, device, owner, envelope)
	if err != nil {
		return AvatarTaskRecord{}, err
	}
	copyEnvelope := envelope
	r.avatar[task.ID] = avatarRelay{Request: &copyEnvelope, ExpiresAt: envelope.ExpiresAt}
	return task, nil
}

func (r *SocialRuntime) RespondAvatar(owner, taskID string, accept bool) error {
	return r.RespondAvatarWithConsent(owner, taskID, accept, false)
}

func (r *SocialRuntime) RespondAvatarWithConsent(owner, taskID string, accept, remember bool) error {
	if remember && !accept {
		return ErrValidation
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.expireAvatarTasks(); err != nil {
		return err
	}
	var err error
	if remember {
		err = r.store.ApproveAvatarTaskPermanently(owner, taskID)
	} else {
		err = r.store.RespondAvatarTask(owner, taskID, accept)
	}
	if err != nil {
		return err
	}
	if !accept {
		delete(r.avatar, taskID)
	}
	return nil
}

func (r *SocialRuntime) StartAvatar(owner, taskID string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.expireAvatarTasks(); err != nil {
		return err
	}
	return r.store.StartAvatarTask(owner, taskID)
}

func (r *SocialRuntime) validateAvatarResult(owner string, task AvatarTaskRecord, envelope AvatarEnvelope) error {
	now := r.now().UTC()
	if envelope.Version != 1 || envelope.TaskID != task.ID || envelope.SenderAccountID != owner || envelope.SenderDeviceID != task.OwnerDeviceID || envelope.RecipientAccountID != task.RequesterID || envelope.RecipientDeviceID != task.RequesterDeviceID || envelope.ExpiresAt.Before(now) || envelope.ExpiresAt.After(envelope.CreatedAt.Add(10*time.Minute)) || len(envelope.Ciphertext) > 44<<10 {
		return ErrAvatarProtocol
	}
	if _, ok := decodeFixedURLBase64(envelope.EphemeralPublicKey, 32); !ok {
		return ErrAvatarProtocol
	}
	if _, ok := decodeFixedURLBase64(envelope.Nonce, 12); !ok {
		return ErrAvatarProtocol
	}
	key, err := r.store.ActiveDeviceKey(owner)
	if err != nil || key.DeviceID != envelope.SenderDeviceID {
		return ErrAvatarProtocol
	}
	publicKey, ok := decodeFixedURLBase64(key.SigningPublicKey, ed25519.PublicKeySize)
	signature, sigOK := decodeFixedURLBase64(envelope.Signature, ed25519.SignatureSize)
	if !ok || !sigOK || !ed25519.Verify(ed25519.PublicKey(publicKey), envelope.SignableBytes(), signature) {
		return ErrAvatarProtocol
	}
	return nil
}

func (r *SocialRuntime) CompleteAvatar(owner, taskID string, envelope AvatarEnvelope) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.expireAvatarTasks(); err != nil {
		return err
	}
	task, err := r.store.AvatarTask(taskID)
	if err != nil {
		return err
	}
	if err = r.validateAvatarResult(owner, task, envelope); err != nil {
		return err
	}
	digest := sha256.Sum256([]byte(envelope.Ciphertext))
	if err = r.store.CompleteAvatarTask(owner, taskID, hex.EncodeToString(digest[:])); err != nil {
		return err
	}
	copyEnvelope := envelope
	relay := r.avatar[taskID]
	relay.Request = nil
	relay.Result = &copyEnvelope
	relay.ExpiresAt = envelope.ExpiresAt
	r.avatar[taskID] = relay
	return nil
}

func (r *SocialRuntime) CancelAvatar(account, taskID string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if err := r.expireAvatarTasks(); err != nil {
		return err
	}
	task, err := r.store.AvatarTask(taskID)
	if err != nil || account != task.OwnerID && account != task.RequesterID {
		return ErrNotFound
	}
	result, err := r.store.db.Exec(`UPDATE avatar_tasks SET state='cancelled',finished_at=? WHERE id=? AND state IN ('pending_approval','routed','running')`, r.now().UnixMilli(), taskID)
	if err != nil {
		return err
	}
	changed, _ := result.RowsAffected()
	if changed == 0 {
		return ErrAvatarTaskExpired
	}
	delete(r.avatar, taskID)
	return nil
}

func (r *SocialRuntime) HasAvatarCiphertext(taskID string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	_, ok := r.avatar[taskID]
	return ok
}

func decodeAvatarCiphertext(envelope AvatarEnvelope) ([]byte, error) {
	return base64.RawURLEncoding.DecodeString(envelope.Ciphertext)
}
