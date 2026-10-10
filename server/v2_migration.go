package main

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

type ClaimInput struct{ LegacyToken, Username, Password, Nickname, DeviceID string }

func (s *SocialStore) MigrateLegacy() error {
	var exists int
	if e := s.db.QueryRow(`SELECT count(*) FROM sqlite_master WHERE type='table' AND name='state'`).Scan(&exists); e != nil || exists == 0 {
		return e
	}
	var raw string
	if e := s.db.QueryRow(`SELECT body FROM state WHERE id=1`).Scan(&raw); e != nil {
		if e == sql.ErrNoRows {
			return nil
		}
		return e
	}
	var old State
	if e := json.Unmarshal([]byte(raw), &old); e != nil {
		return e
	}
	tx, e := s.db.Begin()
	if e != nil {
		return e
	}
	defer tx.Rollback()
	now := time.Now().UnixMilli()
	mapping := map[string]string{}
	for id, u := range old.Users {
		if !u.Paired {
			continue
		}
		account := "acc_legacy_" + id
		mapping[id] = account
		friendID := "PL-LEGACY-" + strings.ToUpper(id)
		placeholder := fmt.Sprintf("pending-%s", strings.ToLower(id))
		if _, e = tx.Exec(`INSERT OR IGNORE INTO accounts(id,username,nickname,friend_id,password_hash,active_device,created_at) VALUES(?,?,?,?,?,?,?)`, account, placeholder, u.Name, friendID, "!unclaimed", "", now); e != nil {
			return e
		}
		if _, e = tx.Exec(`INSERT OR IGNORE INTO legacy_claims(token_hash,account_id) VALUES(?,?)`, u.TokenHash, account); e != nil {
			return e
		}
	}
	for id, p := range old.Pets {
		account, ok := mapping[id]
		if !ok {
			continue
		}
		location := mapping[p.Location]
		if location == "" {
			location = account
		}
		target := mapping[p.Target]
		if _, e = tx.Exec(`INSERT OR IGNORE INTO pets(owner_id,location_id,target_id,phase,revision,style,wave_seq) VALUES(?,?,?,?,?,?,?)`, account, location, target, p.Phase, p.Revision, p.Style, p.Wave); e != nil {
			return e
		}
	}
	ids := make([]string, 0, len(mapping))
	for _, id := range mapping {
		ids = append(ids, id)
	}
	for i := 0; i < len(ids); i++ {
		for j := i + 1; j < len(ids); j++ {
			lo, hi := pairIDs(ids[i], ids[j])
			if _, e = tx.Exec(`INSERT OR IGNORE INTO friendships(user_low,user_high,created_at) VALUES(?,?,?)`, lo, hi, now); e != nil {
				return e
			}
			if _, e = tx.Exec(`INSERT OR IGNORE INTO contact_policies(owner_id,peer_id) VALUES(?,?),(?,?)`, ids[i], ids[j], ids[j], ids[i]); e != nil {
				return e
			}
		}
	}
	for oldOwner, u := range old.Users {
		owner := mapping[oldOwner]
		for oldPeer, allowed := range u.Allows {
			peer := mapping[oldPeer]
			if owner != "" && peer != "" && allowed {
				if _, e = tx.Exec(`UPDATE contact_policies SET trusted=1 WHERE owner_id=? AND peer_id=?`, owner, peer); e != nil {
					return e
				}
			}
		}
	}
	return tx.Commit()
}

func (s *SocialStore) ClaimLegacy(in ClaimInput) (AuthResult, error) {
	in.Username = normalizeUsername(in.Username)
	in.Nickname = strings.TrimSpace(in.Nickname)
	in.DeviceID = strings.TrimSpace(in.DeviceID)
	if !usernameRE.MatchString(in.Username) || in.Nickname == "" || in.DeviceID == "" {
		return AuthResult{}, ErrValidation
	}
	s.passwordGate <- struct{}{}
	ph, e := passwordHash(in.Password)
	<-s.passwordGate
	if e != nil {
		return AuthResult{}, e
	}
	tx, e := s.db.Begin()
	if e != nil {
		return AuthResult{}, e
	}
	defer tx.Rollback()
	var account string
	var claimed sql.NullInt64
	if e = tx.QueryRow(`SELECT account_id,claimed_at FROM legacy_claims WHERE token_hash=?`, hashValue(strings.TrimSpace(in.LegacyToken))).Scan(&account, &claimed); e != nil || claimed.Valid {
		return AuthResult{}, ErrUnauthorized
	}
	recovery := randomToken()
	now := time.Now().UnixMilli()
	if _, e = tx.Exec(`UPDATE accounts SET username=?,nickname=?,password_hash=?,active_device=? WHERE id=?`, in.Username, in.Nickname, ph, in.DeviceID, account); e != nil {
		if strings.Contains(e.Error(), "accounts.username") {
			return AuthResult{}, ErrUsernameTaken
		}
		return AuthResult{}, e
	}
	if _, e = tx.Exec(`INSERT OR REPLACE INTO recovery_codes(account_id,code_hash,used_at) VALUES(?,?,NULL)`, account, hashValue(recovery)); e != nil {
		return AuthResult{}, e
	}
	if _, e = tx.Exec(`UPDATE legacy_claims SET claimed_at=? WHERE account_id=?`, now, account); e != nil {
		return AuthResult{}, e
	}
	out, e := s.issueSession(tx, account, in.DeviceID)
	if e != nil {
		return AuthResult{}, e
	}
	out.RecoveryCode = recovery
	return out, tx.Commit()
}
