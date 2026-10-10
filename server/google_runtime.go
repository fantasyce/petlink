package main

import "time"

// The runtime mutex serializes session handover with snapshot/lease issuance.
// Existing leases are deliberately retained until their actual expiry. A new
// socket cannot shorten another device's display permission.
func (r *SocialRuntime) IssueGoogleSession(accountID, deviceID string, takeover bool) (AuthResult, error) {
	if deviceID == "" || len(deviceID) > 128 {
		return AuthResult{}, ErrValidation
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	tx, e := r.store.db.Begin()
	if e != nil {
		return AuthResult{}, e
	}
	defer tx.Rollback()
	var active, method string
	if e = tx.QueryRow(`SELECT active_device,auth_method FROM accounts WHERE id=?`, accountID).Scan(&active, &method); e != nil || method != "google" {
		return AuthResult{}, ErrUnauthorized
	}
	if active != "" && active != deviceID && !takeover {
		return AuthResult{}, ErrTakeoverRequired
	}
	now := time.Now().UnixMilli()
	if _, e = tx.Exec(`UPDATE avatar_tasks SET state='revoked',error_code='AVATAR_TASK_REVOKED',finished_at=? WHERE (owner_id=? OR requester_id=?) AND state IN ('pending_approval','routed','running')`, now, accountID, accountID); e != nil {
		return AuthResult{}, e
	}
	if active != deviceID {
		if _, e = tx.Exec(`UPDATE device_keys SET revoked_at=? WHERE account_id=? AND revoked_at IS NULL`, now, accountID); e != nil {
			return AuthResult{}, e
		}
	}
	result, e := r.store.issueSession(tx, accountID, deviceID)
	if e != nil {
		return AuthResult{}, e
	}
	if e = tx.Commit(); e != nil {
		return AuthResult{}, e
	}
	delete(r.sessions, accountID)
	for key, relay := range r.avatar {
		_ = relay
		task, e := r.store.AvatarTask(key)
		if e != nil || task.OwnerID == accountID || task.RequesterID == accountID {
			delete(r.avatar, key)
		}
	}
	return result, nil
}
