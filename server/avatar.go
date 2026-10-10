package main

import (
	"crypto/ed25519"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"
	"time"
)

var (
	ErrAvatarNotEnabled    = errors.New("AVATAR_NOT_ENABLED")
	ErrAvatarPetNotPresent = errors.New("AVATAR_PET_NOT_PRESENT")
	ErrAvatarPolicyChanged = errors.New("AVATAR_POLICY_CHANGED")
	ErrAvatarBusy          = errors.New("AVATAR_BUSY")
	ErrAvatarRateLimited   = errors.New("AVATAR_RATE_LIMITED")
	ErrAvatarProtocol      = errors.New("AVATAR_PROTOCOL_ERROR")
	ErrAvatarTaskExpired   = errors.New("AVATAR_TASK_EXPIRED")
	ErrAvatarTaskRevoked   = errors.New("AVATAR_TASK_REVOKED")
)

const (
	AvatarPendingApproval = "pending_approval"
	AvatarRouted          = "routed"
	AvatarRunning         = "running"
	AvatarCompleted       = "completed"
	AvatarRejected        = "rejected"
	AvatarCancelled       = "cancelled"
	AvatarExpired         = "expired"
	AvatarFailed          = "failed"
	AvatarRevoked         = "revoked"
)

type DeviceKey struct {
	AccountID          string `json:"account_id"`
	DeviceID           string `json:"device_id"`
	KeyVersion         int64  `json:"key_version"`
	AgreementPublicKey string `json:"agreement_public_key"`
	SigningPublicKey   string `json:"signing_public_key"`
}

type AvatarPolicy struct {
	AllowAutoAsk bool   `json:"allow_auto_ask"`
	Provider     string `json:"provider"`
	Revision     int64  `json:"policy_revision"`
}

type AvatarContactCapability struct {
	OwnerID            string `json:"owner_id"`
	DeviceID           string `json:"device_id"`
	KeyVersion         int64  `json:"key_version"`
	AgreementPublicKey string `json:"agreement_public_key"`
	SigningPublicKey   string `json:"signing_public_key"`
	VisitRevision      int64  `json:"visit_revision"`
	PolicyRevision     int64  `json:"policy_revision"`
	AllowAutoAsk       bool   `json:"allow_auto_ask"`
	Provider           string `json:"provider"`
}

type AvatarEnvelope struct {
	Version            int       `json:"version"`
	TaskID             string    `json:"task_id"`
	SenderAccountID    string    `json:"sender_account_id"`
	SenderDeviceID     string    `json:"sender_device_id"`
	RecipientAccountID string    `json:"recipient_account_id"`
	RecipientDeviceID  string    `json:"recipient_device_id"`
	VisitRevision      int64     `json:"visit_revision"`
	PolicyRevision     int64     `json:"policy_revision"`
	Sequence           int64     `json:"sequence"`
	CreatedAt          time.Time `json:"created_at"`
	ExpiresAt          time.Time `json:"expires_at"`
	EphemeralPublicKey string    `json:"ephemeral_public_key"`
	Nonce              string    `json:"nonce"`
	Ciphertext         string    `json:"ciphertext"`
	Signature          string    `json:"signature"`
}

func (e AvatarEnvelope) SignableBytes() []byte {
	fields := []string{
		fmt.Sprintf("version=%d", e.Version),
		"task_id=" + e.TaskID,
		"sender_account_id=" + e.SenderAccountID,
		"sender_device_id=" + e.SenderDeviceID,
		"recipient_account_id=" + e.RecipientAccountID,
		"recipient_device_id=" + e.RecipientDeviceID,
		fmt.Sprintf("visit_revision=%d", e.VisitRevision),
		fmt.Sprintf("policy_revision=%d", e.PolicyRevision),
		fmt.Sprintf("sequence=%d", e.Sequence),
		fmt.Sprintf("created_at_ms=%d", e.CreatedAt.UnixMilli()),
		fmt.Sprintf("expires_at_ms=%d", e.ExpiresAt.UnixMilli()),
		"ephemeral_public_key=" + e.EphemeralPublicKey,
		"nonce=" + e.Nonce,
		"ciphertext=" + e.Ciphertext,
	}
	return []byte(strings.Join(fields, "\n"))
}

type AvatarTaskRecord struct {
	ID                string `json:"id"`
	OwnerID           string `json:"owner_id"`
	RequesterID       string `json:"requester_id"`
	RequesterDeviceID string `json:"requester_device_id"`
	OwnerDeviceID     string `json:"owner_device_id"`
	Provider          string `json:"provider"`
	State             string `json:"state"`
	VisitRevision     int64  `json:"visit_revision"`
	PolicyRevision    int64  `json:"policy_revision"`
	RequestDigest     string `json:"request_digest"`
	ResultDigest      string `json:"result_digest,omitempty"`
	CreatedAtMS       int64  `json:"created_at"`
	ExpiresAtMS       int64  `json:"expires_at"`
	ErrorCode         string `json:"error_code,omitempty"`
}

func validAvatarProvider(provider string) bool {
	switch provider {
	case "owner_default", "codex", "claude", "deepseek":
		return true
	default:
		return false
	}
}

func decodeFixedURLBase64(value string, length int) ([]byte, bool) {
	b, err := base64.RawURLEncoding.DecodeString(value)
	return b, err == nil && len(b) == length
}

func (s *SocialStore) RegisterDeviceKeys(account, device, agreement, signing string) (DeviceKey, error) {
	agreementBytes, agreementOK := decodeFixedURLBase64(agreement, 32)
	signingBytes, signingOK := decodeFixedURLBase64(signing, ed25519.PublicKeySize)
	if !agreementOK || !signingOK || len(agreementBytes) == 0 || len(signingBytes) == 0 {
		return DeviceKey{}, ErrAvatarProtocol
	}
	var active string
	if err := s.db.QueryRow(`SELECT active_device FROM accounts WHERE id=?`, account).Scan(&active); err != nil || active != device {
		return DeviceKey{}, ErrDeviceReplaced
	}
	tx, err := s.db.Begin()
	if err != nil {
		return DeviceKey{}, err
	}
	defer tx.Rollback()
	// A reconnect keeps the long-term key version and replay sequence. Old keys
	// created before explicit authorization become usable only through this call.
	var existing DeviceKey
	if err = tx.QueryRow(`SELECT account_id,device_id,key_version,agreement_public_key,signing_public_key FROM device_keys WHERE account_id=? AND device_id=? AND revoked_at IS NULL`, account, device).Scan(&existing.AccountID, &existing.DeviceID, &existing.KeyVersion, &existing.AgreementPublicKey, &existing.SigningPublicKey); err == nil && existing.AgreementPublicKey == agreement && existing.SigningPublicKey == signing {
		if _, err = tx.Exec(`INSERT OR IGNORE INTO avatar_authorizations(account_id,device_id,key_version,authorized_at) VALUES(?,?,?,?)`, account, device, existing.KeyVersion, time.Now().UnixMilli()); err != nil {
			return DeviceKey{}, err
		}
		if err = tx.Commit(); err != nil {
			return DeviceKey{}, err
		}
		return existing, nil
	} else if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return DeviceKey{}, err
	}
	var version int64
	_ = tx.QueryRow(`SELECT COALESCE(max(key_version),0)+1 FROM device_keys WHERE account_id=? AND device_id=?`, account, device).Scan(&version)
	now := time.Now().UnixMilli()
	if _, err = tx.Exec(`UPDATE device_keys SET revoked_at=? WHERE account_id=? AND device_id=? AND revoked_at IS NULL`, now, account, device); err != nil {
		return DeviceKey{}, err
	}
	if _, err = tx.Exec(`INSERT INTO device_keys(account_id,device_id,key_version,agreement_public_key,signing_public_key,created_at) VALUES(?,?,?,?,?,?)`, account, device, version, agreement, signing, now); err != nil {
		return DeviceKey{}, err
	}
	if _, err = tx.Exec(`INSERT INTO avatar_authorizations(account_id,device_id,key_version,authorized_at) VALUES(?,?,?,?)`, account, device, version, now); err != nil {
		return DeviceKey{}, err
	}
	if err = tx.Commit(); err != nil {
		return DeviceKey{}, err
	}
	return DeviceKey{account, device, version, agreement, signing}, nil
}

func (s *SocialStore) ActiveDeviceKey(account string) (DeviceKey, error) {
	var key DeviceKey
	err := s.db.QueryRow(`SELECT d.account_id,d.device_id,d.key_version,d.agreement_public_key,d.signing_public_key FROM device_keys d JOIN accounts a ON a.id=d.account_id AND a.active_device=d.device_id JOIN avatar_authorizations consent ON consent.account_id=d.account_id AND consent.device_id=d.device_id AND consent.key_version=d.key_version WHERE d.account_id=? AND d.revoked_at IS NULL`, account).Scan(&key.AccountID, &key.DeviceID, &key.KeyVersion, &key.AgreementPublicKey, &key.SigningPublicKey)
	if errors.Is(err, sql.ErrNoRows) {
		return DeviceKey{}, ErrAvatarNotEnabled
	}
	return key, err
}

func (s *SocialStore) AvatarPolicy(owner, peer string) (AvatarPolicy, error) {
	var friendship int
	low, high := pairIDs(owner, peer)
	if err := s.db.QueryRow(`SELECT count(*) FROM friendships WHERE user_low=? AND user_high=?`, low, high).Scan(&friendship); err != nil || friendship == 0 {
		return AvatarPolicy{}, ErrNotFriends
	}
	var p AvatarPolicy
	err := s.db.QueryRow(`SELECT allow_auto_ask,provider,policy_revision FROM avatar_policies WHERE owner_id=? AND peer_id=?`, owner, peer).Scan(&p.AllowAutoAsk, &p.Provider, &p.Revision)
	if errors.Is(err, sql.ErrNoRows) {
		return AvatarPolicy{Provider: "owner_default"}, nil
	}
	return p, err
}

func (s *SocialStore) SetAvatarPolicy(owner, peer string, requested AvatarPolicy) (AvatarPolicy, error) {
	if !validAvatarProvider(requested.Provider) {
		return AvatarPolicy{}, ErrValidation
	}
	s.mutationMu.Lock()
	defer s.mutationMu.Unlock()
	if _, err := s.AvatarPolicy(owner, peer); err != nil {
		return AvatarPolicy{}, err
	}
	tx, err := s.db.Begin()
	if err != nil {
		return AvatarPolicy{}, err
	}
	defer tx.Rollback()
	now := time.Now().UnixMilli()
	_, err = tx.Exec(`INSERT INTO avatar_policies(owner_id,peer_id,allow_auto_ask,provider,policy_revision,updated_at) VALUES(?,?,?,?,1,?) ON CONFLICT(owner_id,peer_id) DO UPDATE SET allow_auto_ask=excluded.allow_auto_ask,provider=excluded.provider,policy_revision=avatar_policies.policy_revision+1,updated_at=excluded.updated_at`, owner, peer, requested.AllowAutoAsk, requested.Provider, now)
	if err != nil {
		return AvatarPolicy{}, err
	}
	// Existing requests carry the previous consent revision. Commit its
	// withdrawal with the new policy so neither pending nor running work can
	// continue under that old permission or return a late answer.
	_, err = tx.Exec(`UPDATE avatar_tasks SET state='revoked',error_code='AVATAR_TASK_REVOKED',finished_at=? WHERE owner_id=? AND requester_id=? AND state IN ('pending_approval','routed','running')`, now, owner, peer)
	if err != nil {
		return AvatarPolicy{}, err
	}
	if err = tx.Commit(); err != nil {
		return AvatarPolicy{}, err
	}
	return s.AvatarPolicy(owner, peer)
}

func (s *SocialStore) AvatarContactCapability(requester, owner string) (AvatarContactCapability, error) {
	policy, err := s.AvatarPolicy(owner, requester)
	if err != nil {
		return AvatarContactCapability{}, err
	}
	key, err := s.ActiveDeviceKey(owner)
	if err != nil {
		return AvatarContactCapability{}, err
	}
	var location, phase string
	var revision int64
	if err = s.db.QueryRow(`SELECT location_id,phase,revision FROM pets WHERE owner_id=?`, owner).Scan(&location, &phase, &revision); err != nil || location != requester || phase != "visit" {
		return AvatarContactCapability{}, ErrAvatarPetNotPresent
	}
	return AvatarContactCapability{OwnerID: owner, DeviceID: key.DeviceID, KeyVersion: key.KeyVersion, AgreementPublicKey: key.AgreementPublicKey, SigningPublicKey: key.SigningPublicKey, VisitRevision: revision, PolicyRevision: policy.Revision, AllowAutoAsk: policy.AllowAutoAsk, Provider: policy.Provider}, nil
}

func (s *SocialStore) validateAvatarEnvelope(tx *sql.Tx, requester, device, owner string, envelope AvatarEnvelope) (DeviceKey, AvatarPolicy, error) {
	now := time.Now().UTC()
	if envelope.Version != 1 || envelope.TaskID == "" || len(envelope.TaskID) > 80 || envelope.SenderAccountID != requester || envelope.SenderDeviceID != device || envelope.RecipientAccountID != owner || envelope.Sequence <= 0 || envelope.ExpiresAt.Before(now) || envelope.CreatedAt.After(now.Add(time.Minute)) || envelope.CreatedAt.Before(now.Add(-2*time.Minute)) || envelope.ExpiresAt.After(envelope.CreatedAt.Add(10*time.Minute)) || len(envelope.Ciphertext) > 44<<10 {
		return DeviceKey{}, AvatarPolicy{}, ErrAvatarProtocol
	}
	if _, ok := decodeFixedURLBase64(envelope.EphemeralPublicKey, 32); !ok {
		return DeviceKey{}, AvatarPolicy{}, ErrAvatarProtocol
	}
	if _, ok := decodeFixedURLBase64(envelope.Nonce, 12); !ok {
		return DeviceKey{}, AvatarPolicy{}, ErrAvatarProtocol
	}
	if _, err := base64.RawURLEncoding.DecodeString(envelope.Ciphertext); err != nil {
		return DeviceKey{}, AvatarPolicy{}, ErrAvatarProtocol
	}
	var activeDevice string
	if err := tx.QueryRow(`SELECT active_device FROM accounts WHERE id=?`, requester).Scan(&activeDevice); err != nil || activeDevice != device {
		return DeviceKey{}, AvatarPolicy{}, ErrAvatarProtocol
	}
	var ownerDevice string
	if err := tx.QueryRow(`SELECT active_device FROM accounts WHERE id=?`, owner).Scan(&ownerDevice); err != nil || ownerDevice != envelope.RecipientDeviceID {
		return DeviceKey{}, AvatarPolicy{}, ErrAvatarProtocol
	}
	var signing string
	var lastSequence int64
	if err := tx.QueryRow(`SELECT d.signing_public_key,d.last_sequence FROM device_keys d JOIN avatar_authorizations c ON c.account_id=d.account_id AND c.device_id=d.device_id AND c.key_version=d.key_version WHERE d.account_id=? AND d.device_id=? AND d.revoked_at IS NULL`, requester, device).Scan(&signing, &lastSequence); err != nil || envelope.Sequence <= lastSequence {
		return DeviceKey{}, AvatarPolicy{}, ErrAvatarProtocol
	}
	publicKey, ok := decodeFixedURLBase64(signing, ed25519.PublicKeySize)
	signature, sigOK := decodeFixedURLBase64(envelope.Signature, ed25519.SignatureSize)
	if !ok || !sigOK || !ed25519.Verify(ed25519.PublicKey(publicKey), envelope.SignableBytes(), signature) {
		return DeviceKey{}, AvatarPolicy{}, ErrAvatarProtocol
	}
	var ownerKey DeviceKey
	if err := tx.QueryRow(`SELECT d.account_id,d.device_id,d.key_version,d.agreement_public_key,d.signing_public_key FROM device_keys d JOIN avatar_authorizations c ON c.account_id=d.account_id AND c.device_id=d.device_id AND c.key_version=d.key_version WHERE d.account_id=? AND d.device_id=? AND d.revoked_at IS NULL`, owner, ownerDevice).Scan(&ownerKey.AccountID, &ownerKey.DeviceID, &ownerKey.KeyVersion, &ownerKey.AgreementPublicKey, &ownerKey.SigningPublicKey); err != nil {
		return DeviceKey{}, AvatarPolicy{}, ErrAvatarNotEnabled
	}
	var location, phase string
	var revision int64
	if err := tx.QueryRow(`SELECT location_id,phase,revision FROM pets WHERE owner_id=?`, owner).Scan(&location, &phase, &revision); err != nil || location != requester || phase != "visit" || revision != envelope.VisitRevision {
		return DeviceKey{}, AvatarPolicy{}, ErrAvatarPetNotPresent
	}
	policy := AvatarPolicy{Provider: "owner_default"}
	err := tx.QueryRow(`SELECT allow_auto_ask,provider,policy_revision FROM avatar_policies WHERE owner_id=? AND peer_id=?`, owner, requester).Scan(&policy.AllowAutoAsk, &policy.Provider, &policy.Revision)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return DeviceKey{}, AvatarPolicy{}, err
	}
	if policy.Revision != envelope.PolicyRevision {
		return DeviceKey{}, AvatarPolicy{}, ErrAvatarPolicyChanged
	}
	return ownerKey, policy, nil
}

func (s *SocialStore) CreateAvatarTask(requester, device, owner string, envelope AvatarEnvelope) (AvatarTaskRecord, error) {
	s.mutationMu.Lock()
	defer s.mutationMu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return AvatarTaskRecord{}, err
	}
	defer tx.Rollback()
	ownerKey, policy, err := s.validateAvatarEnvelope(tx, requester, device, owner, envelope)
	if err != nil {
		return AvatarTaskRecord{}, err
	}
	var active int
	if err = tx.QueryRow(`SELECT count(*) FROM avatar_tasks WHERE owner_id=? AND state IN ('pending_approval','routed','running')`, owner).Scan(&active); err != nil {
		return AvatarTaskRecord{}, err
	}
	if active > 0 {
		return AvatarTaskRecord{}, ErrAvatarBusy
	}
	if policy.AllowAutoAsk {
		var recent, peerDaily, ownerDaily int
		now := time.Now().UTC()
		day := now.Format("2006-01-02")
		if err = tx.QueryRow(`SELECT count(*) FROM avatar_tasks WHERE owner_id=? AND requester_id=? AND created_at>=?`, owner, requester, now.Add(-10*time.Minute).UnixMilli()).Scan(&recent); err != nil {
			return AvatarTaskRecord{}, err
		}
		_ = tx.QueryRow(`SELECT accepted_count FROM avatar_usage WHERE owner_id=? AND peer_id=? AND utc_day=?`, owner, requester, day).Scan(&peerDaily)
		if err = tx.QueryRow(`SELECT COALESCE(sum(accepted_count),0) FROM avatar_usage WHERE owner_id=? AND utc_day=?`, owner, day).Scan(&ownerDaily); err != nil {
			return AvatarTaskRecord{}, err
		}
		if recent >= 3 || peerDaily >= 10 || ownerDaily >= 30 {
			return AvatarTaskRecord{}, ErrAvatarRateLimited
		}
	}
	state := AvatarPendingApproval
	if policy.AllowAutoAsk {
		state = AvatarRouted
	}
	digest := sha256.Sum256([]byte(envelope.Ciphertext))
	record := AvatarTaskRecord{ID: envelope.TaskID, OwnerID: owner, RequesterID: requester, RequesterDeviceID: device, OwnerDeviceID: ownerKey.DeviceID, Provider: policy.Provider, State: state, VisitRevision: envelope.VisitRevision, PolicyRevision: policy.Revision, RequestDigest: hex.EncodeToString(digest[:]), CreatedAtMS: envelope.CreatedAt.UnixMilli(), ExpiresAtMS: envelope.ExpiresAt.UnixMilli()}
	_, err = tx.Exec(`INSERT INTO avatar_tasks(id,owner_id,requester_id,requester_device_id,owner_device_id,provider,state,visit_revision,policy_revision,request_digest,created_at,expires_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)`, record.ID, record.OwnerID, record.RequesterID, record.RequesterDeviceID, record.OwnerDeviceID, record.Provider, record.State, record.VisitRevision, record.PolicyRevision, record.RequestDigest, record.CreatedAtMS, record.ExpiresAtMS)
	if err != nil {
		return AvatarTaskRecord{}, ErrAvatarProtocol
	}
	if _, err = tx.Exec(`UPDATE device_keys SET last_sequence=? WHERE account_id=? AND device_id=? AND revoked_at IS NULL`, envelope.Sequence, requester, device); err != nil {
		return AvatarTaskRecord{}, err
	}
	if policy.AllowAutoAsk {
		day := time.Now().UTC().Format("2006-01-02")
		if _, err = tx.Exec(`INSERT INTO avatar_usage(owner_id,peer_id,utc_day,accepted_count) VALUES(?,?,?,1) ON CONFLICT(owner_id,peer_id,utc_day) DO UPDATE SET accepted_count=accepted_count+1`, owner, requester, day); err != nil {
			return AvatarTaskRecord{}, err
		}
	}
	if err = tx.Commit(); err != nil {
		return AvatarTaskRecord{}, err
	}
	return record, nil
}

func scanAvatarTask(row interface{ Scan(...any) error }) (AvatarTaskRecord, error) {
	var task AvatarTaskRecord
	err := row.Scan(&task.ID, &task.OwnerID, &task.RequesterID, &task.RequesterDeviceID, &task.OwnerDeviceID, &task.Provider, &task.State, &task.VisitRevision, &task.PolicyRevision, &task.RequestDigest, &task.ResultDigest, &task.CreatedAtMS, &task.ExpiresAtMS, &task.ErrorCode)
	return task, err
}

const avatarTaskSelect = `SELECT id,owner_id,requester_id,requester_device_id,owner_device_id,provider,state,visit_revision,policy_revision,request_digest,result_digest,created_at,expires_at,error_code FROM avatar_tasks`

func (s *SocialStore) AvatarTask(id string) (AvatarTaskRecord, error) {
	task, err := scanAvatarTask(s.db.QueryRow(avatarTaskSelect+` WHERE id=?`, id))
	if errors.Is(err, sql.ErrNoRows) {
		return AvatarTaskRecord{}, ErrNotFound
	}
	return task, err
}

func (s *SocialStore) RespondAvatarTask(owner, id string, accept bool) error {
	next := AvatarRejected
	if accept {
		next = AvatarRouted
	}
	result, err := s.db.Exec(`UPDATE avatar_tasks SET state=?,accepted_at=? WHERE id=? AND owner_id=? AND state='pending_approval' AND expires_at>?`, next, time.Now().UnixMilli(), id, owner, time.Now().UnixMilli())
	if err != nil {
		return err
	}
	changed, _ := result.RowsAffected()
	if changed == 0 {
		return ErrAvatarTaskExpired
	}
	return nil
}

// Keep the current signed envelope's revision: this question receives explicit
// one-time consent, while a new policy revision governs future questions.
func (s *SocialStore) ApproveAvatarTaskPermanently(owner, id string) error {
	s.mutationMu.Lock()
	defer s.mutationMu.Unlock()
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	task, err := scanAvatarTask(tx.QueryRow(avatarTaskSelect+` WHERE id=? AND owner_id=? AND state='pending_approval' AND expires_at>?`, id, owner, time.Now().UnixMilli()))
	if errors.Is(err, sql.ErrNoRows) {
		return ErrAvatarTaskExpired
	}
	if err != nil {
		return err
	}
	low, high := pairIDs(owner, task.RequesterID)
	var friends int
	if err = tx.QueryRow(`SELECT count(*) FROM friendships WHERE user_low=? AND user_high=?`, low, high).Scan(&friends); err != nil {
		return err
	}
	if friends == 0 {
		return ErrNotFriends
	}
	now := time.Now().UnixMilli()
	_, err = tx.Exec(`INSERT INTO avatar_policies(owner_id,peer_id,allow_auto_ask,provider,policy_revision,updated_at) VALUES(?,?,1,'owner_default',1,?) ON CONFLICT(owner_id,peer_id) DO UPDATE SET allow_auto_ask=1,policy_revision=avatar_policies.policy_revision+1,updated_at=excluded.updated_at`, owner, task.RequesterID, now)
	if err != nil {
		return err
	}
	// Other tasks still carry the superseded policy. Do not upgrade their consent.
	_, err = tx.Exec(`UPDATE avatar_tasks SET state='revoked',error_code='AVATAR_TASK_REVOKED',finished_at=? WHERE owner_id=? AND requester_id=? AND id<>? AND state IN ('pending_approval','routed','running')`, now, owner, task.RequesterID, id)
	if err != nil {
		return err
	}
	result, err := tx.Exec(`UPDATE avatar_tasks SET state='routed',accepted_at=? WHERE id=? AND owner_id=? AND state='pending_approval' AND expires_at>?`, now, id, owner, time.Now().UnixMilli())
	if err != nil {
		return err
	}
	if changed, _ := result.RowsAffected(); changed != 1 {
		return ErrAvatarTaskExpired
	}
	return tx.Commit()
}

func (s *SocialStore) StartAvatarTask(owner, id string) error {
	result, err := s.db.Exec(`UPDATE avatar_tasks SET state='running',started_at=? WHERE id=? AND owner_id=? AND state='routed' AND expires_at>?`, time.Now().UnixMilli(), id, owner, time.Now().UnixMilli())
	if err != nil {
		return err
	}
	changed, _ := result.RowsAffected()
	if changed == 0 {
		return ErrAvatarTaskExpired
	}
	return nil
}

func (s *SocialStore) CompleteAvatarTask(owner, id, resultDigest string) error {
	if len(resultDigest) != 64 || strings.Trim(resultDigest, "0123456789abcdef") != "" {
		return ErrAvatarProtocol
	}
	result, err := s.db.Exec(`UPDATE avatar_tasks SET state='completed',result_digest=?,finished_at=? WHERE id=? AND owner_id=? AND state='running' AND expires_at>?`, resultDigest, time.Now().UnixMilli(), id, owner, time.Now().UnixMilli())
	if err != nil {
		return err
	}
	changed, _ := result.RowsAffected()
	if changed > 0 {
		return nil
	}
	task, lookup := s.AvatarTask(id)
	if lookup == nil && task.State == AvatarRevoked {
		return ErrAvatarTaskRevoked
	}
	return ErrAvatarTaskExpired
}

func (s *SocialStore) RevokeAvatarTasks(owner, code string) error {
	_, err := s.db.Exec(`UPDATE avatar_tasks SET state='revoked',error_code=?,finished_at=? WHERE owner_id=? AND state IN ('pending_approval','routed','running')`, code, time.Now().UnixMilli(), owner)
	return err
}

// Relationship removal and task revocation commit together. Concurrent task
// transitions either precede this transaction or see the terminal revoked state.
func revokeRelationshipAvatarTasks(tx *sql.Tx, a, b string) error {
	_, err := tx.Exec(`UPDATE avatar_tasks SET state='revoked',error_code='AVATAR_TASK_REVOKED',finished_at=? WHERE state IN ('pending_approval','routed','running') AND ((owner_id=? AND requester_id=?) OR (owner_id=? AND requester_id=?))`, time.Now().UnixMilli(), a, b, b, a)
	return err
}
