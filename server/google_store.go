package main

import (
	"crypto/subtle"
	"database/sql"
	"errors"
	"strings"
	"time"
	"unicode/utf8"
)

var (
	ErrGoogleAlreadyLinked  = errors.New("GOOGLE_ALREADY_LINKED")
	ErrAccountAlreadyLinked = errors.New("ACCOUNT_ALREADY_LINKED")
	ErrMigrationRequired    = errors.New("MIGRATION_REQUIRED")
	ErrMigrationClosed      = errors.New("MIGRATION_CLOSED")
)

func (s *SocialStore) MigrateGoogleSchema() error {
	tx, e := s.db.Begin()
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if _, e = tx.Exec(`CREATE TABLE IF NOT EXISTS auth_schema_version(id INTEGER PRIMARY KEY CHECK(id=1),version INTEGER NOT NULL)`); e != nil {
		return e
	}
	var v int
	e = tx.QueryRow(`SELECT version FROM auth_schema_version WHERE id=1`).Scan(&v)
	if e != nil && !errors.Is(e, sql.ErrNoRows) {
		return e
	}
	if v > 2 {
		return errors.New("AUTH_SCHEMA_UNSUPPORTED")
	}
	if v == 0 {
		for _, q := range []string{
			`ALTER TABLE accounts ADD COLUMN auth_method TEXT NOT NULL DEFAULT 'legacy' CHECK(auth_method IN ('legacy','google'))`,
			`CREATE TABLE google_identities(account_id TEXT NOT NULL UNIQUE REFERENCES accounts(id),issuer TEXT NOT NULL,subject TEXT NOT NULL,email TEXT NOT NULL,linked_at INTEGER NOT NULL,updated_at INTEGER NOT NULL,PRIMARY KEY(issuer,subject))`,
			`INSERT INTO auth_schema_version(id,version) VALUES(1,1)`,
		} {
			if _, e = tx.Exec(q); e != nil {
				return e
			}
		}
	}
	if v < 2 {
		if _, e = tx.Exec(`ALTER TABLE accounts ADD COLUMN nickname_is_default INTEGER NOT NULL DEFAULT 0 CHECK(nickname_is_default IN (0,1))`); e != nil {
			return e
		}
		if _, e = tx.Exec(`UPDATE auth_schema_version SET version=2 WHERE id=1`); e != nil {
			return e
		}
	}
	return tx.Commit()
}
func validGoogleIdentity(i GoogleIdentity) bool {
	return i.Issuer == "https://accounts.google.com" && i.Subject != "" && len(i.Subject) <= 255 && i.Email != "" && len(i.Email) <= 320
}
func (s *SocialStore) ResolveGoogle(identity GoogleIdentity, nickname string) (string, bool, error) {
	if !validGoogleIdentity(identity) {
		return "", false, ErrGoogleIdentityInvalid
	}
	s.mutationMu.Lock()
	defer s.mutationMu.Unlock()
	tx, e := s.db.Begin()
	if e != nil {
		return "", false, e
	}
	defer tx.Rollback()
	var id string
	e = tx.QueryRow(`SELECT account_id FROM google_identities WHERE issuer=? AND subject=?`, identity.Issuer, identity.Subject).Scan(&id)
	if e == nil {
		var existingName, friendID string
		if e = tx.QueryRow(`SELECT nickname,friend_id FROM accounts WHERE id=?`, id).Scan(&existingName, &friendID); e != nil {
			return "", false, e
		}
		if strings.TrimSpace(existingName) == "" {
			suffix := friendID
			if len(suffix) > 4 {
				suffix = suffix[len(suffix)-4:]
			}
			if _, e = tx.Exec(`UPDATE accounts SET nickname=?,nickname_is_default=1 WHERE id=?`, "小伙伴"+suffix, id); e != nil {
				return "", false, e
			}
		}
		_, e = tx.Exec(`UPDATE google_identities SET email=?,updated_at=? WHERE account_id=?`, identity.Email, time.Now().UnixMilli(), id)
		if e != nil {
			return "", false, e
		}
		return id, false, tx.Commit()
	}
	if !errors.Is(e, sql.ErrNoRows) {
		return "", false, e
	}
	nickname = strings.TrimSpace(nickname)
	friendID := newFriendID()
	isDefault := nickname == ""
	if isDefault {
		nickname = "小伙伴" + friendID[len(friendID)-4:]
	}
	if !utf8.ValidString(nickname) || utf8.RuneCountInString(nickname) < 1 || utf8.RuneCountInString(nickname) > 40 {
		return "", false, ErrValidation
	}
	id = newID("acct_")
	now := time.Now().UnixMilli()
	if _, e = tx.Exec(`INSERT INTO accounts(id,username,nickname,friend_id,password_hash,active_device,created_at,auth_method,nickname_is_default) VALUES(?,?,?,?,?,'',?,'google',?)`, id, newID("google_"), nickname, friendID, "", now, isDefault); e != nil {
		return "", false, e
	}
	if _, e = tx.Exec(`INSERT INTO pets(owner_id,location_id,style) VALUES(?,?,8)`, id, id); e != nil {
		return "", false, e
	}
	if _, e = tx.Exec(`INSERT INTO google_identities(account_id,issuer,subject,email,linked_at,updated_at) VALUES(?,?,?,?,?,?)`, id, identity.Issuer, identity.Subject, identity.Email, now, now); e != nil {
		return "", false, e
	}
	return id, true, tx.Commit()
}
func (s *SocialStore) ProveLegacy(username, password, recoveryCode string) (GoogleProof, error) {
	empty := GoogleProof{}
	if len(username) > 128 || len(password) > 128 || len(recoveryCode) > 256 || (password == "") == (recoveryCode == "") {
		return empty, ErrUnauthorized
	}
	var id, hash, method string
	if e := s.db.QueryRow(`SELECT id,password_hash,auth_method FROM accounts WHERE username=?`, normalizeUsername(username)).Scan(&id, &hash, &method); e != nil || method != "legacy" {
		return empty, ErrUnauthorized
	}
	if password != "" {
		s.passwordGate <- struct{}{}
		ok := verifyPassword(hash, password)
		<-s.passwordGate
		if !ok {
			return empty, ErrUnauthorized
		}
		return GoogleProof{AccountID: id, PasswordHash: hash}, nil
	}
	digest := hashValue(strings.TrimSpace(recoveryCode))
	var stored string
	var used sql.NullInt64
	if e := s.db.QueryRow(`SELECT code_hash,used_at FROM recovery_codes WHERE account_id=?`, id).Scan(&stored, &used); e != nil || used.Valid || subtle.ConstantTimeCompare([]byte(digest), []byte(stored)) != 1 {
		return empty, ErrUnauthorized
	}
	return GoogleProof{AccountID: id, RecoveryHash: stored}, nil
}
func (s *SocialStore) AuthMigrationAccess(token string) (GoogleProof, error) {
	var p GoogleProof
	e := s.db.QueryRow(`SELECT a.id,s.id FROM sessions s JOIN accounts a ON a.id=s.account_id WHERE s.access_hash=? AND s.revoked=0 AND s.access_expires>? AND a.auth_method='legacy'`, hashValue(token), time.Now().UnixMilli()).Scan(&p.AccountID, &p.SessionID)
	if e != nil {
		return GoogleProof{}, ErrUnauthorized
	}
	return p, nil
}
func checkGoogleProof(tx *sql.Tx, p GoogleProof) error {
	var method, stored string
	if e := tx.QueryRow(`SELECT auth_method,password_hash FROM accounts WHERE id=?`, p.AccountID).Scan(&method, &stored); e != nil {
		return ErrUnauthorized
	}
	if method != "legacy" {
		return ErrAccountAlreadyLinked
	}
	count := 0
	if p.SessionID != "" {
		count++
	}
	if p.PasswordHash != "" {
		count++
	}
	if p.RecoveryHash != "" {
		count++
	}
	if count != 1 {
		return ErrUnauthorized
	}
	if p.PasswordHash != "" {
		if subtle.ConstantTimeCompare([]byte(p.PasswordHash), []byte(stored)) != 1 {
			return ErrUnauthorized
		}
		return nil
	}
	if p.RecoveryHash != "" {
		var used sql.NullInt64
		if e := tx.QueryRow(`SELECT code_hash,used_at FROM recovery_codes WHERE account_id=?`, p.AccountID).Scan(&stored, &used); e != nil || used.Valid || subtle.ConstantTimeCompare([]byte(stored), []byte(p.RecoveryHash)) != 1 {
			return ErrUnauthorized
		}
		return nil
	}
	var n int
	if e := tx.QueryRow(`SELECT count(*) FROM sessions WHERE id=? AND account_id=? AND revoked=0 AND access_expires>?`, p.SessionID, p.AccountID, time.Now().UnixMilli()).Scan(&n); e != nil || n != 1 {
		return ErrUnauthorized
	}
	return nil
}
func (s *SocialStore) LinkGoogle(proof GoogleProof, identity GoogleIdentity) error {
	if !validGoogleIdentity(identity) {
		return ErrGoogleIdentityInvalid
	}
	s.mutationMu.Lock()
	defer s.mutationMu.Unlock()
	tx, e := s.db.Begin()
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if e = checkGoogleProof(tx, proof); e != nil {
		return e
	}
	var n int
	if e = tx.QueryRow(`SELECT count(*) FROM google_identities WHERE issuer=? AND subject=?`, identity.Issuer, identity.Subject).Scan(&n); e != nil {
		return e
	}
	if n != 0 {
		return ErrGoogleAlreadyLinked
	}
	now := time.Now().UnixMilli()
	if _, e = tx.Exec(`INSERT INTO google_identities(account_id,issuer,subject,email,linked_at,updated_at) VALUES(?,?,?,?,?,?)`, proof.AccountID, identity.Issuer, identity.Subject, identity.Email, now, now); e != nil {
		return e
	}
	for _, q := range []string{`UPDATE accounts SET auth_method='google',password_hash='' WHERE id=?`, `DELETE FROM recovery_codes WHERE account_id=?`, `UPDATE sessions SET revoked=1 WHERE account_id=?`} {
		if _, e = tx.Exec(q, proof.AccountID); e != nil {
			return e
		}
	}
	return tx.Commit()
}

// SetNickname edits only the authenticated account; blank values never erase a name.
func (s *SocialStore) SetNickname(account, nickname string) error {
	nickname = strings.TrimSpace(nickname)
	if !utf8.ValidString(nickname) || utf8.RuneCountInString(nickname) < 1 || utf8.RuneCountInString(nickname) > 40 {
		return ErrValidation
	}
	s.mutationMu.Lock()
	defer s.mutationMu.Unlock()
	result, e := s.db.Exec(`UPDATE accounts SET nickname=?,nickname_is_default=0 WHERE id=?`, nickname, account)
	if e != nil {
		return e
	}
	n, e := result.RowsAffected()
	if e != nil {
		return e
	}
	if n != 1 {
		return ErrNotFound
	}
	return nil
}
