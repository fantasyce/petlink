package main

import (
	"crypto/rand"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
	"golang.org/x/crypto/argon2"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	_ "modernc.org/sqlite"
)

var (
	ErrInviteInvalid    = errors.New("INVITE_INVALID")
	ErrLoginFailed      = errors.New("LOGIN_FAILED")
	ErrTakeoverRequired = errors.New("TAKEOVER_REQUIRED")
	ErrUnauthorized     = errors.New("UNAUTHORIZED")
	ErrRequestExists    = errors.New("REQUEST_EXISTS")
	ErrBlocked          = errors.New("BLOCKED")
	ErrNotFriends       = errors.New("NOT_FRIENDS")
	ErrNotFound         = errors.New("NOT_FOUND")
	ErrHostFull         = errors.New("HOST_FULL")
	ErrHostPaused       = errors.New("HOST_PAUSED")
	ErrRequestExpired   = errors.New("REQUEST_EXPIRED")
	ErrValidation       = errors.New("VALIDATION_FAILED")
	ErrDeviceReplaced   = errors.New("DEVICE_REPLACED")
	ErrUsernameTaken    = errors.New("USERNAME_TAKEN")
)

type RegisterInput struct{ Invite, Username, Password, Nickname, DeviceID string }
type LoginInput struct{ Username, Password, DeviceID string }
type TakeoverInput = LoginInput
type AuthResult struct {
	AccountID    string `json:"account_id"`
	FriendID     string `json:"friend_id"`
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	RecoveryCode string `json:"recovery_code,omitempty"`
}
type RecoverInput struct{ Username, RecoveryCode, NewPassword, DeviceID string }
type AccountProfile struct {
	Style             int    `json:"style"`
	NicknameIsDefault bool   `json:"nickname_is_default"`
	AccountID         string `json:"account_id"`
	Username          string `json:"username"`
	Nickname          string `json:"nickname"`
	FriendID          string `json:"friend_id"`
	ActiveDevice      string `json:"active_device"`
	Accepting         bool   `json:"accepting"`
}
type FriendRequest struct {
	ID        string    `json:"id"`
	FromID    string    `json:"from_id"`
	ToID      string    `json:"to_id"`
	Status    string    `json:"status"`
	ExpiresAt time.Time `json:"expires_at"`
}
type Contact struct {
	Style      int    `json:"style"`
	AccountID  string `json:"account_id"`
	FriendID   string `json:"friend_id"`
	Nickname   string `json:"nickname"`
	Note       string `json:"note"`
	Trusted    bool   `json:"trusted"`
	ShareAgent bool   `json:"share_agent"`
}
type ContactPolicy struct {
	Trusted    bool   `json:"trusted"`
	ShareAgent bool   `json:"share_agent"`
	Note       string `json:"note"`
}
type VisitRequest struct {
	ID        string    `json:"id"`
	GuestID   string    `json:"guest_id"`
	HostID    string    `json:"host_id"`
	Status    string    `json:"status"`
	ExpiresAt time.Time `json:"expires_at"`
}
type AgentStatus struct {
	Provider   string    `json:"provider"`
	SessionRef string    `json:"session_ref"`
	State      string    `json:"state"`
	Sequence   int64     `json:"sequence"`
	ExpiresAt  time.Time `json:"expires_at"`
}

type SocialStore struct {
	googleOnly   atomic.Bool
	db           *sql.DB
	passwordGate chan struct{}
	mutationMu   sync.Mutex
	mu           sync.Mutex
	agent        map[string]AgentStatus
}

var usernameRE = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{2,31}$`)

const socialSchema = `
PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;
CREATE TABLE IF NOT EXISTS accounts(id TEXT PRIMARY KEY,username TEXT NOT NULL UNIQUE,nickname TEXT NOT NULL,friend_id TEXT NOT NULL UNIQUE,password_hash TEXT NOT NULL,active_device TEXT NOT NULL,accepting INTEGER NOT NULL DEFAULT 1,created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS devices(id TEXT NOT NULL,account_id TEXT NOT NULL,active INTEGER NOT NULL,created_at INTEGER NOT NULL,PRIMARY KEY(account_id,id));
CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,account_id TEXT NOT NULL,device_id TEXT NOT NULL,access_hash TEXT NOT NULL UNIQUE,refresh_hash TEXT NOT NULL UNIQUE,access_expires INTEGER NOT NULL,refresh_expires INTEGER NOT NULL,revoked INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS invites(code_hash TEXT PRIMARY KEY,expires_at INTEGER NOT NULL,used_at INTEGER);
CREATE TABLE IF NOT EXISTS recovery_codes(account_id TEXT PRIMARY KEY,code_hash TEXT NOT NULL,used_at INTEGER);
CREATE TABLE IF NOT EXISTS friendships(user_low TEXT NOT NULL,user_high TEXT NOT NULL,created_at INTEGER NOT NULL,PRIMARY KEY(user_low,user_high));
CREATE TABLE IF NOT EXISTS friend_requests(id TEXT PRIMARY KEY,from_id TEXT NOT NULL,to_id TEXT NOT NULL,status TEXT NOT NULL,expires_at INTEGER NOT NULL,created_at INTEGER NOT NULL);
CREATE UNIQUE INDEX IF NOT EXISTS one_pending_friend_request ON friend_requests(from_id,to_id) WHERE status='pending';
CREATE TABLE IF NOT EXISTS contact_policies(owner_id TEXT NOT NULL,peer_id TEXT NOT NULL,trusted INTEGER NOT NULL DEFAULT 0,share_agent INTEGER NOT NULL DEFAULT 0,note TEXT NOT NULL DEFAULT '',PRIMARY KEY(owner_id,peer_id));
CREATE TABLE IF NOT EXISTS blocks(blocker_id TEXT NOT NULL,blocked_id TEXT NOT NULL,created_at INTEGER NOT NULL,PRIMARY KEY(blocker_id,blocked_id));
CREATE TABLE IF NOT EXISTS pets(owner_id TEXT PRIMARY KEY,location_id TEXT NOT NULL,target_id TEXT NOT NULL DEFAULT '',phase TEXT NOT NULL DEFAULT 'home',revision INTEGER NOT NULL DEFAULT 1,style INTEGER NOT NULL DEFAULT 0,wave_seq INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS visit_requests(id TEXT PRIMARY KEY,guest_id TEXT NOT NULL,host_id TEXT NOT NULL,status TEXT NOT NULL,expires_at INTEGER NOT NULL,created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS display_leases(pet_id TEXT PRIMARY KEY,device_id TEXT NOT NULL,session_id TEXT NOT NULL,revision INTEGER NOT NULL,expires_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS agent_sharing_policies(owner_id TEXT NOT NULL,peer_id TEXT NOT NULL,enabled INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(owner_id,peer_id));
CREATE TABLE IF NOT EXISTS legacy_claims(token_hash TEXT PRIMARY KEY,account_id TEXT NOT NULL UNIQUE,claimed_at INTEGER);
CREATE TABLE IF NOT EXISTS idempotency(account_id TEXT NOT NULL,request_id TEXT NOT NULL,response_json TEXT NOT NULL,created_at INTEGER NOT NULL,PRIMARY KEY(account_id,request_id));
CREATE TABLE IF NOT EXISTS device_keys(account_id TEXT NOT NULL,device_id TEXT NOT NULL,key_version INTEGER NOT NULL,agreement_public_key TEXT NOT NULL,signing_public_key TEXT NOT NULL,last_sequence INTEGER NOT NULL DEFAULT 0,created_at INTEGER NOT NULL,revoked_at INTEGER,PRIMARY KEY(account_id,device_id,key_version));
CREATE UNIQUE INDEX IF NOT EXISTS one_active_device_key ON device_keys(account_id,device_id) WHERE revoked_at IS NULL;
CREATE TABLE IF NOT EXISTS avatar_authorizations(account_id TEXT NOT NULL,device_id TEXT NOT NULL,key_version INTEGER NOT NULL,authorized_at INTEGER NOT NULL,PRIMARY KEY(account_id,device_id,key_version));
CREATE TABLE IF NOT EXISTS avatar_policies(owner_id TEXT NOT NULL,peer_id TEXT NOT NULL,allow_auto_ask INTEGER NOT NULL DEFAULT 0,provider TEXT NOT NULL DEFAULT 'owner_default',policy_revision INTEGER NOT NULL DEFAULT 0,updated_at INTEGER NOT NULL,PRIMARY KEY(owner_id,peer_id));
CREATE TABLE IF NOT EXISTS avatar_tasks(id TEXT PRIMARY KEY,owner_id TEXT NOT NULL,requester_id TEXT NOT NULL,requester_device_id TEXT NOT NULL,owner_device_id TEXT NOT NULL,provider TEXT NOT NULL,state TEXT NOT NULL,visit_revision INTEGER NOT NULL,policy_revision INTEGER NOT NULL,request_digest TEXT NOT NULL,result_digest TEXT NOT NULL DEFAULT '',created_at INTEGER NOT NULL,accepted_at INTEGER,started_at INTEGER,finished_at INTEGER,expires_at INTEGER NOT NULL,error_code TEXT NOT NULL DEFAULT '');
CREATE INDEX IF NOT EXISTS avatar_tasks_owner_state ON avatar_tasks(owner_id,state);
CREATE TABLE IF NOT EXISTS avatar_usage(owner_id TEXT NOT NULL,peer_id TEXT NOT NULL,utc_day TEXT NOT NULL,accepted_count INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(owner_id,peer_id,utc_day));`

func OpenSocialStore(path string) (*SocialStore, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err = db.Exec(socialSchema); err != nil {
		db.Close()
		return nil, err
	}
	if _, err = db.Exec(`UPDATE avatar_tasks SET state='failed',error_code='SERVER_RESTARTED',finished_at=? WHERE state IN ('pending_approval','routed','running')`, time.Now().UnixMilli()); err != nil {
		db.Close()
		return nil, err
	}
	s := &SocialStore{db: db, passwordGate: make(chan struct{}, 1), agent: map[string]AgentStatus{}}
	if err = s.MigrateGoogleSchema(); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}
func (s *SocialStore) Close() error { return s.db.Close() }

func hashValue(v string) string { return digest(v) }
func randomBytes(n int) []byte {
	b := make([]byte, n)
	if _, e := rand.Read(b); e != nil {
		panic(e)
	}
	return b
}
func newID(prefix string) string {
	return prefix + base64.RawURLEncoding.EncodeToString(randomBytes(12))
}
func newFriendID() string {
	return "PL-" + strings.ToUpper(base64.RawURLEncoding.EncodeToString(randomBytes(7)))
}

func passwordHash(password string) (string, error) {
	if len(password) < 12 || len(password) > 128 {
		return "", ErrValidation
	}
	salt := randomBytes(16)
	h := argon2.IDKey([]byte(password), salt, 2, 19*1024, 1, 32)
	return fmt.Sprintf("argon2id$v=19$m=19456,t=2,p=1$%s$%s", base64.RawStdEncoding.EncodeToString(salt), base64.RawStdEncoding.EncodeToString(h)), nil
}
func verifyPassword(encoded, password string) bool {
	parts := strings.Split(encoded, "$")
	if len(parts) != 5 || parts[0] != "argon2id" || parts[1] != "v=19" || parts[2] != "m=19456,t=2,p=1" {
		return false
	}
	salt64, hash64 := parts[3], parts[4]
	salt, e1 := base64.RawStdEncoding.DecodeString(salt64)
	expected, e2 := base64.RawStdEncoding.DecodeString(hash64)
	if e1 != nil || e2 != nil {
		return false
	}
	actual := argon2.IDKey([]byte(password), salt, 2, 19*1024, 1, uint32(len(expected)))
	return subtle.ConstantTimeCompare(actual, expected) == 1
}

func (s *SocialStore) CreateInvite(code string, expires time.Time) error {
	if strings.TrimSpace(code) == "" {
		return ErrValidation
	}
	_, err := s.db.Exec(`INSERT INTO invites(code_hash,expires_at) VALUES(?,?)`, hashValue(strings.TrimSpace(code)), expires.UnixMilli())
	return err
}

func normalizeUsername(v string) string { return strings.ToLower(strings.TrimSpace(v)) }
func (s *SocialStore) issueSession(tx *sql.Tx, accountID, deviceID string) (AuthResult, error) {
	access, refresh := randomToken(), randomToken()
	now := time.Now()
	sid := newID("ses_")
	if _, e := tx.Exec(`UPDATE sessions SET revoked=1 WHERE account_id=?`, accountID); e != nil {
		return AuthResult{}, e
	}
	if _, e := tx.Exec(`INSERT INTO sessions(id,account_id,device_id,access_hash,refresh_hash,access_expires,refresh_expires) VALUES(?,?,?,?,?,?,?)`, sid, accountID, deviceID, hashValue(access), hashValue(refresh), now.Add(15*time.Minute).UnixMilli(), now.Add(30*24*time.Hour).UnixMilli()); e != nil {
		return AuthResult{}, e
	}
	if _, e := tx.Exec(`INSERT INTO devices(id,account_id,active,created_at) VALUES(?,?,1,?) ON CONFLICT(account_id,id) DO UPDATE SET active=1`, deviceID, accountID, now.UnixMilli()); e != nil {
		return AuthResult{}, e
	}
	if _, e := tx.Exec(`UPDATE devices SET active=CASE WHEN id=? THEN 1 ELSE 0 END WHERE account_id=?`, deviceID, accountID); e != nil {
		return AuthResult{}, e
	}
	if _, e := tx.Exec(`UPDATE accounts SET active_device=? WHERE id=?`, deviceID, accountID); e != nil {
		return AuthResult{}, e
	}
	var friendID string
	if e := tx.QueryRow(`SELECT friend_id FROM accounts WHERE id=?`, accountID).Scan(&friendID); e != nil {
		return AuthResult{}, e
	}
	return AuthResult{AccountID: accountID, FriendID: friendID, AccessToken: access, RefreshToken: refresh}, nil
}

func (s *SocialStore) Register(in RegisterInput) (out AuthResult, err error) {
	in.Username = normalizeUsername(in.Username)
	in.Nickname = strings.TrimSpace(in.Nickname)
	in.Invite = strings.TrimSpace(in.Invite)
	in.DeviceID = strings.TrimSpace(in.DeviceID)
	if !usernameRE.MatchString(in.Username) || in.Nickname == "" || len([]rune(in.Nickname)) > 40 || in.DeviceID == "" {
		return out, ErrValidation
	}
	s.passwordGate <- struct{}{}
	ph, e := passwordHash(in.Password)
	<-s.passwordGate
	if e != nil {
		return out, e
	}
	tx, e := s.db.Begin()
	if e != nil {
		return out, e
	}
	defer func() {
		if err != nil {
			tx.Rollback()
		}
	}()
	now := time.Now().UnixMilli()
	var expires int64
	var used sql.NullInt64
	if e = tx.QueryRow(`SELECT expires_at,used_at FROM invites WHERE code_hash=?`, hashValue(in.Invite)).Scan(&expires, &used); e != nil || used.Valid || expires < now {
		return out, ErrInviteInvalid
	}
	accountID, recovery := newID("acc_"), randomToken()
	if _, e = tx.Exec(`INSERT INTO accounts(id,username,nickname,friend_id,password_hash,active_device,created_at) VALUES(?,?,?,?,?,?,?)`, accountID, in.Username, in.Nickname, newFriendID(), ph, in.DeviceID, now); e != nil {
		if strings.Contains(e.Error(), "accounts.username") {
			return out, ErrUsernameTaken
		}
		return out, e
	}
	if _, e = tx.Exec(`UPDATE invites SET used_at=? WHERE code_hash=? AND used_at IS NULL`, now, hashValue(in.Invite)); e != nil {
		return out, e
	}
	if _, e = tx.Exec(`INSERT INTO recovery_codes(account_id,code_hash) VALUES(?,?)`, accountID, hashValue(recovery)); e != nil {
		return out, e
	}
	if _, e = tx.Exec(`INSERT INTO pets(owner_id,location_id) VALUES(?,?)`, accountID, accountID); e != nil {
		return out, e
	}
	out, e = s.issueSession(tx, accountID, in.DeviceID)
	if e != nil {
		return out, e
	}
	out.RecoveryCode = recovery
	e = tx.Commit()
	return out, e
}

func (s *SocialStore) authenticatePassword(username, password string) (string, string, error) {
	var id, hash, device string
	e := s.db.QueryRow(`SELECT id,password_hash,active_device FROM accounts WHERE username=? AND auth_method='legacy'`, normalizeUsername(username)).Scan(&id, &hash, &device)
	if e != nil {
		return "", "", ErrLoginFailed
	}
	s.passwordGate <- struct{}{}
	ok := verifyPassword(hash, password)
	<-s.passwordGate
	if !ok {
		return "", "", ErrLoginFailed
	}
	return id, device, nil
}
func (s *SocialStore) login(in LoginInput, takeover bool) (AuthResult, error) {
	id, active, e := s.authenticatePassword(in.Username, in.Password)
	if e != nil {
		return AuthResult{}, e
	}
	if active != in.DeviceID && !takeover {
		return AuthResult{}, ErrTakeoverRequired
	}
	tx, e := s.db.Begin()
	if e != nil {
		return AuthResult{}, e
	}
	out, e := s.issueSession(tx, id, in.DeviceID)
	if e != nil {
		tx.Rollback()
		return AuthResult{}, e
	}
	return out, tx.Commit()
}
func (s *SocialStore) Login(in LoginInput) (AuthResult, error)       { return s.login(in, false) }
func (s *SocialStore) Takeover(in TakeoverInput) (AuthResult, error) { return s.login(in, true) }
func (s *SocialStore) AuthAccess(token string) (string, error) {
	var id string
	e := s.db.QueryRow(`SELECT account_id FROM sessions WHERE access_hash=? AND revoked=0 AND access_expires>?`, hashValue(token), time.Now().UnixMilli()).Scan(&id)
	if e != nil {
		return "", ErrUnauthorized
	}
	if s.googleOnly.Load() {
		var method string
		if e = s.db.QueryRow(`SELECT auth_method FROM accounts WHERE id=?`, id).Scan(&method); e != nil || method != "google" {
			return "", ErrMigrationRequired
		}
	}
	return id, nil
}
func (s *SocialStore) Logout(access string) error {
	res, e := s.db.Exec(`UPDATE sessions SET revoked=1 WHERE access_hash=? AND revoked=0`, hashValue(access))
	if e != nil {
		return e
	}
	n, _ := res.RowsAffected()
	if n != 1 {
		return ErrUnauthorized
	}
	return nil
}
func (s *SocialStore) Refresh(token string) (AuthResult, error) {
	tx, e := s.db.Begin()
	if e != nil {
		return AuthResult{}, e
	}
	defer tx.Rollback()
	var account, device string
	if e = tx.QueryRow(`SELECT account_id,device_id FROM sessions WHERE refresh_hash=? AND revoked=0 AND refresh_expires>?`, hashValue(token), time.Now().UnixMilli()).Scan(&account, &device); e != nil {
		return AuthResult{}, ErrUnauthorized
	}
	if s.googleOnly.Load() {
		var method string
		if e = tx.QueryRow(`SELECT auth_method FROM accounts WHERE id=?`, account).Scan(&method); e != nil || method != "google" {
			return AuthResult{}, ErrMigrationRequired
		}
	}
	out, e := s.issueSession(tx, account, device)
	if e != nil {
		return AuthResult{}, e
	}
	return out, tx.Commit()
}
func (s *SocialStore) Recover(in RecoverInput) (AuthResult, error) {
	in.Username = normalizeUsername(in.Username)
	s.passwordGate <- struct{}{}
	ph, e := passwordHash(in.NewPassword)
	<-s.passwordGate
	if e != nil {
		return AuthResult{}, e
	}
	tx, e := s.db.Begin()
	if e != nil {
		return AuthResult{}, e
	}
	defer tx.Rollback()
	var id, stored string
	var used sql.NullInt64
	if e = tx.QueryRow(`SELECT a.id,r.code_hash,r.used_at FROM accounts a JOIN recovery_codes r ON r.account_id=a.id WHERE a.username=?`, in.Username).Scan(&id, &stored, &used); e != nil || used.Valid || subtle.ConstantTimeCompare([]byte(stored), []byte(hashValue(strings.TrimSpace(in.RecoveryCode)))) != 1 {
		return AuthResult{}, ErrUnauthorized
	}
	now := time.Now().UnixMilli()
	next := randomToken()
	if _, e = tx.Exec(`UPDATE accounts SET password_hash=? WHERE id=?`, ph, id); e != nil {
		return AuthResult{}, e
	}
	if _, e = tx.Exec(`UPDATE recovery_codes SET code_hash=?,used_at=NULL WHERE account_id=?`, hashValue(next), id); e != nil {
		return AuthResult{}, e
	}
	out, e := s.issueSession(tx, id, in.DeviceID)
	if e != nil {
		return AuthResult{}, e
	}
	out.RecoveryCode = next
	_ = now
	return out, tx.Commit()
}
func (s *SocialStore) Profile(account string) (AccountProfile, error) {
	var p AccountProfile
	e := s.db.QueryRow(`SELECT a.id,a.username,a.nickname,a.friend_id,a.active_device,a.accepting,a.nickname_is_default,COALESCE(p.style,0) FROM accounts a LEFT JOIN pets p ON p.owner_id=a.id WHERE a.id=?`, account).Scan(&p.AccountID, &p.Username, &p.Nickname, &p.FriendID, &p.ActiveDevice, &p.Accepting, &p.NicknameIsDefault, &p.Style)
	return p, e
}

func pairIDs(a, b string) (string, string) {
	if a < b {
		return a, b
	}
	return b, a
}
func (s *SocialStore) blocked(a, b string) bool {
	var n int
	_ = s.db.QueryRow(`SELECT count(*) FROM blocks WHERE (blocker_id=? AND blocked_id=?) OR (blocker_id=? AND blocked_id=?)`, a, b, b, a).Scan(&n)
	return n > 0
}
func (s *SocialStore) friends(a, b string) bool {
	lo, hi := pairIDs(a, b)
	var n int
	_ = s.db.QueryRow(`SELECT count(*) FROM friendships WHERE user_low=? AND user_high=?`, lo, hi).Scan(&n)
	return n > 0
}
func (s *SocialStore) RequestFriend(from, friendID string) (FriendRequest, error) {
	s.mutationMu.Lock()
	defer s.mutationMu.Unlock()
	var to string
	if e := s.db.QueryRow(`SELECT id FROM accounts WHERE friend_id=?`, strings.ToUpper(strings.TrimSpace(friendID))).Scan(&to); e != nil || to == from {
		return FriendRequest{}, ErrNotFound
	}
	if s.blocked(from, to) {
		return FriendRequest{}, ErrBlocked
	}
	if s.friends(from, to) {
		return FriendRequest{}, ErrRequestExists
	}
	_, _ = s.db.Exec(`UPDATE friend_requests SET status='expired' WHERE status='pending' AND expires_at<?`, time.Now().UnixMilli())
	var n int
	_ = s.db.QueryRow(`SELECT count(*) FROM friend_requests WHERE ((from_id=? AND to_id=?) OR (from_id=? AND to_id=?)) AND status='pending'`, from, to, to, from).Scan(&n)
	if n > 0 {
		return FriendRequest{}, ErrRequestExists
	}
	now := time.Now()
	r := FriendRequest{ID: newID("frq_"), FromID: from, ToID: to, Status: "pending", ExpiresAt: now.Add(7 * 24 * time.Hour)}
	_, e := s.db.Exec(`INSERT INTO friend_requests(id,from_id,to_id,status,expires_at,created_at) VALUES(?,?,?,?,?,?)`, r.ID, from, to, r.Status, r.ExpiresAt.UnixMilli(), now.UnixMilli())
	return r, e
}
func (s *SocialStore) RespondFriend(account, requestID string, accept bool) error {
	s.mutationMu.Lock()
	defer s.mutationMu.Unlock()
	tx, e := s.db.Begin()
	if e != nil {
		return e
	}
	defer tx.Rollback()
	var from, to, status string
	var expires int64
	if e = tx.QueryRow(`SELECT from_id,to_id,status,expires_at FROM friend_requests WHERE id=?`, requestID).Scan(&from, &to, &status, &expires); e != nil || to != account {
		return ErrNotFound
	}
	if status != "pending" || expires < time.Now().UnixMilli() {
		return ErrRequestExpired
	}
	newStatus := "rejected"
	if accept {
		newStatus = "accepted"
		lo, hi := pairIDs(from, to)
		if _, e = tx.Exec(`INSERT INTO friendships(user_low,user_high,created_at) VALUES(?,?,?)`, lo, hi, time.Now().UnixMilli()); e != nil {
			return e
		}
		for _, p := range [][2]string{{from, to}, {to, from}} {
			if _, e = tx.Exec(`INSERT OR IGNORE INTO contact_policies(owner_id,peer_id) VALUES(?,?)`, p[0], p[1]); e != nil {
				return e
			}
		}
	}
	if _, e = tx.Exec(`UPDATE friend_requests SET status=? WHERE id=?`, newStatus, requestID); e != nil {
		return e
	}
	return tx.Commit()
}
func (s *SocialStore) Contacts(account string) ([]Contact, error) {
	rows, e := s.db.Query(`SELECT a.id,a.friend_id,a.nickname,COALESCE(p.note,''),COALESCE(p.trusted,0),COALESCE(p.share_agent,0),COALESCE(pet.style,0) FROM accounts a JOIN friendships f ON (f.user_low=? AND a.id=f.user_high) OR (f.user_high=? AND a.id=f.user_low) LEFT JOIN contact_policies p ON p.owner_id=? AND p.peer_id=a.id LEFT JOIN pets pet ON pet.owner_id=a.id ORDER BY a.nickname`, account, account, account)
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	var out []Contact
	for rows.Next() {
		var c Contact
		if e = rows.Scan(&c.AccountID, &c.FriendID, &c.Nickname, &c.Note, &c.Trusted, &c.ShareAgent, &c.Style); e != nil {
			return nil, e
		}
		out = append(out, c)
	}
	return out, rows.Err()
}
func (s *SocialStore) PendingFriendRequests(account string) ([]FriendRequest, error) {
	rows, e := s.db.Query(`SELECT id,from_id,to_id,status,expires_at FROM friend_requests WHERE to_id=? AND status='pending' AND expires_at>? ORDER BY created_at`, account, time.Now().UnixMilli())
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	var out []FriendRequest
	for rows.Next() {
		var r FriendRequest
		var ms int64
		if e = rows.Scan(&r.ID, &r.FromID, &r.ToID, &r.Status, &ms); e != nil {
			return nil, e
		}
		r.ExpiresAt = time.UnixMilli(ms)
		out = append(out, r)
	}
	return out, rows.Err()
}
func (s *SocialStore) Block(owner, peer string) error {
	tx, e := s.db.Begin()
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if e = revokeRelationshipAvatarTasks(tx, owner, peer); e != nil {
		return e
	}
	lo, hi := pairIDs(owner, peer)
	if _, e = tx.Exec(`DELETE FROM friendships WHERE user_low=? AND user_high=?`, lo, hi); e != nil {
		return e
	}
	if _, e = tx.Exec(`DELETE FROM friend_requests WHERE (from_id=? AND to_id=?) OR (from_id=? AND to_id=?)`, owner, peer, peer, owner); e != nil {
		return e
	}
	if _, e = tx.Exec(`UPDATE pets SET target_id=owner_id,phase='travel',revision=revision+1 WHERE (owner_id=? AND (location_id=? OR target_id=?)) OR (owner_id=? AND (location_id=? OR target_id=?))`, owner, peer, peer, peer, owner, owner); e != nil {
		return e
	}
	if _, e = tx.Exec(`UPDATE visit_requests SET status='cancelled' WHERE status IN ('pending','accepted') AND ((guest_id=? AND host_id=?) OR (guest_id=? AND host_id=?))`, owner, peer, peer, owner); e != nil {
		return e
	}
	if _, e = tx.Exec(`INSERT OR IGNORE INTO blocks(blocker_id,blocked_id,created_at) VALUES(?,?,?)`, owner, peer, time.Now().UnixMilli()); e != nil {
		return e
	}
	return tx.Commit()
}
func (s *SocialStore) RemoveFriend(owner, peer string) error {
	tx, e := s.db.Begin()
	if e != nil {
		return e
	}
	defer tx.Rollback()
	if e = revokeRelationshipAvatarTasks(tx, owner, peer); e != nil {
		return e
	}
	lo, hi := pairIDs(owner, peer)
	res, e := tx.Exec(`DELETE FROM friendships WHERE user_low=? AND user_high=?`, lo, hi)
	if e != nil {
		return e
	}
	n, _ := res.RowsAffected()
	if n != 1 {
		return ErrNotFriends
	}
	_, _ = tx.Exec(`DELETE FROM contact_policies WHERE (owner_id=? AND peer_id=?) OR (owner_id=? AND peer_id=?)`, owner, peer, peer, owner)
	_, _ = tx.Exec(`UPDATE pets SET target_id=owner_id,phase='travel',revision=revision+1 WHERE (owner_id=? AND (location_id=? OR target_id=?)) OR (owner_id=? AND (location_id=? OR target_id=?))`, owner, peer, peer, peer, owner, owner)
	_, _ = tx.Exec(`UPDATE visit_requests SET status='cancelled' WHERE status IN ('pending','accepted') AND ((guest_id=? AND host_id=?) OR (guest_id=? AND host_id=?))`, owner, peer, peer, owner)
	return tx.Commit()
}
func (s *SocialStore) SetContactPolicy(owner, peer string, p ContactPolicy) error {
	if !s.friends(owner, peer) {
		return ErrNotFriends
	}
	tx, e := s.db.Begin()
	if e != nil {
		return e
	}
	defer tx.Rollback()
	var wasTrusted bool
	_ = tx.QueryRow(`SELECT trusted FROM contact_policies WHERE owner_id=? AND peer_id=?`, owner, peer).Scan(&wasTrusted)
	if _, e = tx.Exec(`INSERT INTO contact_policies(owner_id,peer_id,trusted,share_agent,note) VALUES(?,?,?,?,?) ON CONFLICT(owner_id,peer_id) DO UPDATE SET trusted=excluded.trusted,share_agent=excluded.share_agent,note=excluded.note`, owner, peer, p.Trusted, p.ShareAgent, strings.TrimSpace(p.Note)); e != nil {
		return e
	}
	if wasTrusted && !p.Trusted {
		_, _ = tx.Exec(`UPDATE pets SET target_id=owner_id,phase='travel',revision=revision+1 WHERE owner_id=? AND (location_id=? OR target_id=?)`, peer, owner, owner)
		_, _ = tx.Exec(`UPDATE visit_requests SET status='completed' WHERE guest_id=? AND host_id=? AND status='accepted'`, peer, owner)
	}
	return tx.Commit()
}

func (s *SocialStore) RequestVisit(guest, host string) (VisitRequest, error) {
	s.mutationMu.Lock()
	defer s.mutationMu.Unlock()
	if !s.friends(guest, host) {
		return VisitRequest{}, ErrNotFriends
	}
	if s.blocked(guest, host) {
		return VisitRequest{}, ErrBlocked
	}
	_, _ = s.db.Exec(`UPDATE visit_requests SET status='expired' WHERE status='pending' AND expires_at<?`, time.Now().UnixMilli())
	var n int
	_ = s.db.QueryRow(`SELECT count(*) FROM visit_requests WHERE guest_id=? AND status IN ('pending','accepted')`, guest).Scan(&n)
	if n > 0 {
		return VisitRequest{}, ErrRequestExists
	}
	var trusted bool
	_ = s.db.QueryRow(`SELECT trusted FROM contact_policies WHERE owner_id=? AND peer_id=?`, host, guest).Scan(&trusted)
	now := time.Now()
	status := "pending"
	if trusted {
		status = "accepted"
		_ = s.db.QueryRow(`SELECT count(*) FROM visit_requests WHERE host_id=? AND status='accepted'`, host).Scan(&n)
		if n >= 3 {
			return VisitRequest{}, ErrHostFull
		}
	}
	r := VisitRequest{ID: newID("vis_"), GuestID: guest, HostID: host, Status: status, ExpiresAt: now.Add(time.Minute)}
	tx, e := s.db.Begin()
	if e != nil {
		return VisitRequest{}, e
	}
	defer tx.Rollback()
	if _, e = tx.Exec(`INSERT INTO visit_requests(id,guest_id,host_id,status,expires_at,created_at) VALUES(?,?,?,?,?,?)`, r.ID, guest, host, status, r.ExpiresAt.UnixMilli(), now.UnixMilli()); e != nil {
		return VisitRequest{}, e
	}
	if status == "accepted" {
		if e = beginPetTransfer(tx, guest, host); e != nil {
			return VisitRequest{}, e
		}
	}
	return r, tx.Commit()
}
func beginPetTransfer(tx *sql.Tx, guest, target string) error {
	res, e := tx.Exec(`UPDATE pets SET target_id=?,phase='travel',revision=revision+1 WHERE owner_id=? AND phase='home' AND location_id=owner_id`, target, guest)
	if e != nil {
		return e
	}
	n, _ := res.RowsAffected()
	if n != 1 {
		return ErrRequestExists
	}
	return nil
}
func (s *SocialStore) RespondVisit(host, requestID string, accept bool) error {
	s.mutationMu.Lock()
	defer s.mutationMu.Unlock()
	tx, e := s.db.Begin()
	if e != nil {
		return e
	}
	defer tx.Rollback()
	var owner, status string
	var expires int64
	if e = tx.QueryRow(`SELECT host_id,status,expires_at FROM visit_requests WHERE id=?`, requestID).Scan(&owner, &status, &expires); e != nil || owner != host {
		return ErrNotFound
	}
	if status != "pending" || expires < time.Now().UnixMilli() {
		return ErrRequestExpired
	}
	next := "rejected"
	if accept {
		var n int
		if e = tx.QueryRow(`SELECT count(*) FROM visit_requests WHERE host_id=? AND status='accepted'`, host).Scan(&n); e != nil {
			return e
		}
		if n >= 3 {
			return ErrHostFull
		}
		next = "accepted"
		var guest string
		if e = tx.QueryRow(`SELECT guest_id FROM visit_requests WHERE id=?`, requestID).Scan(&guest); e != nil {
			return e
		}
		if e = beginPetTransfer(tx, guest, host); e != nil {
			return e
		}
	}
	if _, e = tx.Exec(`UPDATE visit_requests SET status=? WHERE id=?`, next, requestID); e != nil {
		return e
	}
	return tx.Commit()
}
func (s *SocialStore) PendingVisitRequests(host string) ([]VisitRequest, error) {
	rows, e := s.db.Query(`SELECT id,guest_id,host_id,status,expires_at FROM visit_requests WHERE host_id=? AND status='pending' AND expires_at>? ORDER BY created_at`, host, time.Now().UnixMilli())
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	var out []VisitRequest
	for rows.Next() {
		var r VisitRequest
		var ms int64
		if e = rows.Scan(&r.ID, &r.GuestID, &r.HostID, &r.Status, &ms); e != nil {
			return nil, e
		}
		r.ExpiresAt = time.UnixMilli(ms)
		out = append(out, r)
	}
	return out, rows.Err()
}
func (s *SocialStore) OutgoingVisitRequests(guest string) ([]VisitRequest, error) {
	rows, e := s.db.Query(`SELECT id,guest_id,host_id,status,expires_at FROM visit_requests WHERE guest_id=? AND status='pending' AND expires_at>? ORDER BY created_at`, guest, time.Now().UnixMilli())
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	var out []VisitRequest
	for rows.Next() {
		var r VisitRequest
		var ms int64
		if e = rows.Scan(&r.ID, &r.GuestID, &r.HostID, &r.Status, &ms); e != nil {
			return nil, e
		}
		r.ExpiresAt = time.UnixMilli(ms)
		out = append(out, r)
	}
	return out, rows.Err()
}

// Bounded requester-only history. Keep pending-only projections compatible with old apps.
func (s *SocialStore) RecentVisitRequests(guest string) ([]VisitRequest, error) {
	rows, e := s.db.Query(`SELECT id,guest_id,host_id,status,expires_at FROM visit_requests WHERE guest_id=? AND created_at>? ORDER BY created_at DESC,rowid DESC LIMIT 20`, guest, time.Now().Add(-24*time.Hour).UnixMilli())
	if e != nil {
		return nil, e
	}
	defer rows.Close()
	out := []VisitRequest{}
	for rows.Next() {
		var r VisitRequest
		var ms int64
		if e = rows.Scan(&r.ID, &r.GuestID, &r.HostID, &r.Status, &ms); e != nil {
			return nil, e
		}
		r.ExpiresAt = time.UnixMilli(ms)
		out = append(out, r)
	}
	return out, rows.Err()
}
func (s *SocialStore) CancelVisit(guest, requestID string) error {
	res, e := s.db.Exec(`UPDATE visit_requests SET status='cancelled' WHERE id=? AND guest_id=? AND status='pending'`, requestID, guest)
	if e != nil {
		return e
	}
	n, _ := res.RowsAffected()
	if n != 1 {
		return ErrNotFound
	}
	return nil
}

var validAgentState = map[string]bool{"disconnected": true, "idle": true, "working": true, "waiting_approval": true, "completed": true, "failed": true, "unknown": true}

func (s *SocialStore) UpdateAgentStatus(owner string, status AgentStatus) error {
	if !validAgentState[status.State] || status.Provider == "" || status.SessionRef == "" {
		return ErrValidation
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if old, ok := s.agent[owner]; ok && time.Now().Before(old.ExpiresAt) && old.Provider == status.Provider && old.SessionRef == status.SessionRef && status.Sequence <= old.Sequence {
		return ErrValidation
	}
	s.agent[owner] = status
	return nil
}
func (s *SocialStore) AgentStatusFor(viewer, owner string) (*AgentStatus, error) {
	if viewer != owner && !s.friends(viewer, owner) {
		return nil, ErrNotFriends
	}
	if viewer != owner {
		var enabled bool
		_ = s.db.QueryRow(`SELECT share_agent FROM contact_policies WHERE owner_id=? AND peer_id=?`, owner, viewer).Scan(&enabled)
		if !enabled {
			return nil, nil
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	v, ok := s.agent[owner]
	if !ok || time.Now().After(v.ExpiresAt) {
		return nil, nil
	}
	return &v, nil
}
