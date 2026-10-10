package main

import (
	"errors"
	"sync"
	"time"
)

type runtimeSession struct {
	DeviceID, SessionID string
	Seen                time.Time
}
type runtimeLease struct {
	DeviceID, SessionID string
	Revision            int64
	ExpiresAt           time.Time
}
type runtimeHideAcknowledgement struct {
	DeviceID, SessionID string
	Revision            int64
	ExpiresAt           time.Time
}
type runtimeHideAcknowledgementKey struct {
	PetID, DeviceID, SessionID string
	Revision                   int64
}
type V2Pet struct {
	OwnerID       string     `json:"owner_id"`
	Nickname      string     `json:"nickname"`
	LocationID    string     `json:"location_id"`
	TargetID      string     `json:"target_id"`
	Phase         string     `json:"phase"`
	Revision      int64      `json:"revision"`
	Style         int        `json:"style"`
	WaveSequence  int64      `json:"wave_sequence"`
	WaveExpiresAt *time.Time `json:"wave_expires_at,omitempty"`
}
type V2Hide struct {
	PetID    string `json:"pet_id"`
	Revision int64  `json:"revision"`
}
type V2Contact struct {
	Style                int          `json:"style"`
	Accepting            bool         `json:"accepting"`
	AccountID            string       `json:"account_id"`
	FriendID             string       `json:"friend_id"`
	Nickname             string       `json:"nickname"`
	Note                 string       `json:"note"`
	Online               bool         `json:"online"`
	Trusted              bool         `json:"trusted"`
	ShareAgent           bool         `json:"share_agent"`
	AutoVisit            bool         `json:"auto_visit"`
	Agent                *AgentStatus `json:"agent,omitempty"`
	AllowAvatarAsk       bool         `json:"allow_avatar_ask"`
	AvatarProvider       string       `json:"avatar_provider"`
	AvatarPolicyRevision int64        `json:"avatar_policy_revision"`
	AvatarKeyReady       bool         `json:"avatar_key_ready"`
}
type V2Snapshot struct {
	RequestID      string            `json:"request_id"`
	Error          string            `json:"error,omitempty"`
	SelfID         string            `json:"self_id"`
	Own            V2Pet             `json:"own"`
	Pets           []V2Pet           `json:"pets"`
	Hides          []V2Hide          `json:"hides"`
	LeaseMS        int               `json:"lease_ms"`
	Contacts       []V2Contact       `json:"contacts"`
	FriendRequests []FriendRequest   `json:"friend_requests"`
	VisitRequests  []VisitRequest    `json:"visit_requests"`
	OutgoingVisits []VisitRequest    `json:"outgoing_visits"`
	VisitHistory   []VisitRequest    `json:"visit_history"`
	AvatarTasks    []AvatarRelayView `json:"avatar_tasks,omitempty"`
}
type AvatarRelayView struct {
	Task    AvatarTaskRecord `json:"task"`
	Request *AvatarEnvelope  `json:"request,omitempty"`
	Result  *AvatarEnvelope  `json:"result,omitempty"`
	PeerKey *DeviceKey       `json:"peer_key,omitempty"`
}
type avatarRelay struct {
	Request   *AvatarEnvelope
	Result    *AvatarEnvelope
	ExpiresAt time.Time
}
type SocialRuntime struct {
	store             *SocialStore
	mu                sync.Mutex
	sessions          map[string]runtimeSession
	leases            map[string]runtimeLease
	acknowledgedHides map[runtimeHideAcknowledgementKey]runtimeHideAcknowledgement
	waves             map[string]time.Time
	avatar            map[string]avatarRelay
	now               func() time.Time
	readyAt           time.Time
	lastExpirySweep   time.Time
}

func NewSocialRuntime(s *SocialStore) *SocialRuntime {
	return &SocialRuntime{store: s, sessions: map[string]runtimeSession{}, leases: map[string]runtimeLease{}, acknowledgedHides: map[runtimeHideAcknowledgementKey]runtimeHideAcknowledgement{}, waves: map[string]time.Time{}, avatar: map[string]avatarRelay{}, now: time.Now, readyAt: time.Now().Add(6 * time.Second)}
}
func (r *SocialRuntime) Connect(account, device, session string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	p, e := r.store.Profile(account)
	if e != nil {
		return ErrUnauthorized
	}
	if p.ActiveDevice != device {
		return ErrDeviceReplaced
	}
	r.sessions[account] = runtimeSession{device, session, r.now()}
	return nil
}
func (r *SocialRuntime) Disconnect(account, session string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.sessions[account].SessionID == session {
		delete(r.sessions, account)
		_, _ = r.store.db.Exec(`UPDATE pets SET target_id=owner_id,phase='travel',revision=revision+1 WHERE (location_id=? OR target_id=?) AND owner_id!=?`, account, account, account)
		_, _ = r.store.db.Exec(`UPDATE pets SET target_id=owner_id,phase='travel',revision=revision+1 WHERE owner_id=? AND (location_id!=owner_id OR (target_id!='' AND target_id!=owner_id))`, account)
		_, _ = r.store.db.Exec(`UPDATE visit_requests SET status='cancelled' WHERE (host_id=? OR guest_id=?) AND status='pending'`, account, account)
		_, _ = r.store.db.Exec(`UPDATE visit_requests SET status='completed' WHERE (host_id=? OR guest_id=?) AND status='accepted'`, account, account)
		_, _ = r.store.db.Exec(`UPDATE avatar_tasks SET state='revoked',error_code='AVATAR_TASK_REVOKED',finished_at=? WHERE (owner_id=? OR requester_id=?) AND state IN ('pending_approval','routed','running')`, r.now().UnixMilli(), account, account)
		for id := range r.avatar {
			task, taskErr := r.store.AvatarTask(id)
			if taskErr == nil && (task.OwnerID == account || task.RequesterID == account) {
				delete(r.avatar, id)
			}
		}
	}
}
func (r *SocialRuntime) online(account string) bool {
	s, ok := r.sessions[account]
	return ok && r.now().Sub(s.Seen) < 10*time.Second
}

func (r *SocialRuntime) tick() error {
	if err := r.expireAvatarTasks(); err != nil {
		return err
	}
	nowTime := r.now()
	now := nowTime.UnixMilli()
	if r.lastExpirySweep.IsZero() || nowTime.Sub(r.lastExpirySweep) >= time.Second {
		for pet, ack := range r.acknowledgedHides {
			if !ack.ExpiresAt.After(nowTime) {
				delete(r.acknowledgedHides, pet)
			}
		}
		_, _ = r.store.db.Exec(`UPDATE visit_requests SET status='expired' WHERE status='pending' AND expires_at<?`, now)
		r.lastExpirySweep = nowTime
	}
	rows, e := r.store.db.Query(`SELECT owner_id,target_id,revision FROM pets WHERE phase='travel'`)
	if e != nil {
		return e
	}
	type item struct {
		o, t string
		rev  int64
	}
	var items []item
	for rows.Next() {
		var x item
		if e = rows.Scan(&x.o, &x.t, &x.rev); e != nil {
			rows.Close()
			return e
		}
		items = append(items, x)
	}
	rows.Close()
	for _, x := range items {
		lease, leased := r.leases[x.o]
		if !leased || lease.Revision >= x.rev || !lease.ExpiresAt.After(nowTime) {
			phase := "visit"
			if x.o == x.t {
				phase = "home"
			}
			if _, e = r.store.db.Exec(`UPDATE pets SET location_id=?,target_id='',phase=?,revision=revision+1 WHERE owner_id=? AND phase='travel'`, x.t, phase, x.o); e != nil {
				return e
			}
			delete(r.leases, x.o)
		}
	}
	return nil
}
func scanV2Pet(row interface{ Scan(...any) error }) (V2Pet, error) {
	var p V2Pet
	e := row.Scan(&p.OwnerID, &p.Nickname, &p.LocationID, &p.TargetID, &p.Phase, &p.Revision, &p.Style, &p.WaveSequence)
	return p, e
}

func (r *SocialRuntime) applyWaveExpiry(pet *V2Pet) {
	if expiry, ok := r.waves[pet.OwnerID]; ok && expiry.After(r.now()) {
		value := expiry
		pet.WaveExpiresAt = &value
	}
}

const v2PetSelect = `SELECT p.owner_id,a.nickname,p.location_id,p.target_id,p.phase,p.revision,p.style,p.wave_seq FROM pets p JOIN accounts a ON a.id=p.owner_id`

func (r *SocialRuntime) Snapshot(account, device, session, request string) (V2Snapshot, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	active, ok := r.sessions[account]
	if !ok || active.DeviceID != device || active.SessionID != session {
		return V2Snapshot{}, ErrUnauthorized
	}
	profile, e := r.store.Profile(account)
	if e != nil || profile.ActiveDevice != device {
		return V2Snapshot{}, ErrDeviceReplaced
	}
	active.Seen = r.now()
	r.sessions[account] = active
	if e = r.tick(); e != nil {
		return V2Snapshot{}, e
	}
	out := V2Snapshot{RequestID: request, SelfID: account, LeaseMS: 3000, Pets: []V2Pet{}, Hides: []V2Hide{}, Contacts: []V2Contact{}, FriendRequests: []FriendRequest{}, VisitRequests: []VisitRequest{}, OutgoingVisits: []VisitRequest{}, AvatarTasks: []AvatarRelayView{}}
	out.Own, e = scanV2Pet(r.store.db.QueryRow(v2PetSelect+` WHERE p.owner_id=?`, account))
	if e != nil {
		return out, e
	}
	r.applyWaveExpiry(&out.Own)
	contacts, e := r.store.Contacts(account)
	if e != nil {
		return out, e
	}
	for _, c := range contacts {
		var accepting bool
		if e = r.store.db.QueryRow(`SELECT accepting FROM accounts WHERE id=?`, c.AccountID).Scan(&accepting); e != nil {
			return out, e
		}
		var auto bool
		_ = r.store.db.QueryRow(`SELECT trusted FROM contact_policies WHERE owner_id=? AND peer_id=?`, c.AccountID, account).Scan(&auto)
		agent, _ := r.store.AgentStatusFor(account, c.AccountID)
		avatarPolicy, _ := r.store.AvatarPolicy(account, c.AccountID)
		_, keyErr := r.store.ActiveDeviceKey(c.AccountID)
		out.Contacts = append(out.Contacts, V2Contact{Style: c.Style, Accepting: accepting, AccountID: c.AccountID, FriendID: c.FriendID, Nickname: c.Nickname, Note: c.Note, Online: r.online(c.AccountID), Trusted: c.Trusted, ShareAgent: c.ShareAgent, AutoVisit: auto, Agent: agent, AllowAvatarAsk: avatarPolicy.AllowAutoAsk, AvatarProvider: avatarPolicy.Provider, AvatarPolicyRevision: avatarPolicy.Revision, AvatarKeyReady: keyErr == nil})
	}
	out.FriendRequests, _ = r.store.PendingFriendRequests(account)
	out.VisitRequests, _ = r.store.PendingVisitRequests(account)
	out.OutgoingVisits, _ = r.store.OutgoingVisitRequests(account)
	out.VisitHistory, e = r.store.RecentVisitRequests(account)
	if e != nil {
		return out, e
	}
	if out.FriendRequests == nil {
		out.FriendRequests = []FriendRequest{}
	}
	if out.VisitRequests == nil {
		out.VisitRequests = []VisitRequest{}
	}
	if out.OutgoingVisits == nil {
		out.OutgoingVisits = []VisitRequest{}
	}
	avatarRows, avatarErr := r.store.db.Query(avatarTaskSelect+` WHERE owner_id=? OR requester_id=? ORDER BY created_at DESC LIMIT 20`, account, account)
	if avatarErr != nil {
		return out, avatarErr
	}
	for avatarRows.Next() {
		task, scanErr := scanAvatarTask(avatarRows)
		if scanErr != nil {
			avatarRows.Close()
			return out, scanErr
		}
		view := AvatarRelayView{Task: task}
		if task.State == AvatarRevoked {
			delete(r.avatar, task.ID)
		}
		if relay, ok := r.avatar[task.ID]; ok && relay.ExpiresAt.After(r.now()) {
			if account == task.OwnerID {
				view.Request = relay.Request
			}
			if account == task.RequesterID {
				view.Result = relay.Result
			}
		}
		out.AvatarTasks = append(out.AvatarTasks, view)
	}
	avatarRows.Close()
	for i := range out.AvatarTasks {
		peerID := out.AvatarTasks[i].Task.OwnerID
		if account == out.AvatarTasks[i].Task.OwnerID {
			peerID = out.AvatarTasks[i].Task.RequesterID
		}
		if key, keyErr := r.store.ActiveDeviceKey(peerID); keyErr == nil {
			out.AvatarTasks[i].PeerKey = &key
		}
	}
	rows, e := r.store.db.Query(v2PetSelect+` WHERE p.location_id=? AND p.phase!='travel' ORDER BY p.owner_id`, account)
	if e != nil {
		return out, e
	}
	var located []V2Pet
	for rows.Next() {
		pet, e := scanV2Pet(rows)
		if e != nil {
			rows.Close()
			return out, e
		}
		r.applyWaveExpiry(&pet)
		located = append(located, pet)
	}
	if e = rows.Err(); e != nil {
		rows.Close()
		return out, e
	}
	rows.Close()
	for _, pet := range located {
		if r.now().Before(r.readyAt) {
			continue
		}
		lease, leased := r.leases[pet.OwnerID]
		if leased && lease.ExpiresAt.After(r.now()) && lease.SessionID != session {
			continue
		}
		r.leases[pet.OwnerID] = runtimeLease{DeviceID: device, SessionID: session, Revision: pet.Revision, ExpiresAt: r.now().Add(5 * time.Second)}
		out.Pets = append(out.Pets, pet)
	}
	hideRows, e := r.store.db.Query(`SELECT owner_id,revision FROM pets WHERE location_id=? AND phase='travel'`, account)
	if e != nil {
		return out, e
	}
	defer hideRows.Close()
	for hideRows.Next() {
		var h V2Hide
		if e = hideRows.Scan(&h.PetID, &h.Revision); e != nil {
			return out, e
		}
		if lease, ok := r.leases[h.PetID]; ok && lease.SessionID == session && lease.Revision < h.Revision {
			out.Hides = append(out.Hides, h)
		}
	}
	return out, nil
}
func (r *SocialRuntime) AckHide(account, device, session, pet string, revision int64) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	s, ok := r.sessions[account]
	if !ok || s.DeviceID != device || s.SessionID != session {
		return ErrUnauthorized
	}
	key := runtimeHideAcknowledgementKey{pet, device, session, revision}
	if ack, ok := r.acknowledgedHides[key]; ok && ack.ExpiresAt.After(r.now()) {
		return nil
	}
	lease, ok := r.leases[pet]
	if !ok || lease.DeviceID != device || lease.SessionID != session || lease.Revision >= revision {
		return ErrRequestExpired
	}
	delete(r.leases, pet)
	r.acknowledgedHides[key] = runtimeHideAcknowledgement{DeviceID: device, SessionID: session, Revision: revision, ExpiresAt: r.now().Add(10 * time.Second)}
	return r.tick()
}
func (r *SocialRuntime) RequestVisit(guest, host string) (VisitRequest, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !r.online(host) {
		return VisitRequest{}, errors.New("PEER_OFFLINE")
	}
	var accepting bool
	if e := r.store.db.QueryRow(`SELECT accepting FROM accounts WHERE id=?`, host).Scan(&accepting); e != nil {
		return VisitRequest{}, ErrNotFound
	}
	if !accepting {
		return VisitRequest{}, ErrHostPaused
	}
	return r.store.RequestVisit(guest, host)
}
func (r *SocialRuntime) Style(account string, style int) error {
	if style < 0 || style > 9 {
		return ErrValidation
	}
	_, e := r.store.db.Exec(`UPDATE pets SET style=? WHERE owner_id=?`, style, account)
	return e
}
func (r *SocialRuntime) Wave(account string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	_, e := r.store.db.Exec(`UPDATE pets SET wave_seq=wave_seq+1 WHERE owner_id=?`, account)
	if e == nil {
		r.waves[account] = r.now().Add(3 * time.Second)
	}
	return e
}
func (r *SocialRuntime) Recall(account string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	_, e := r.store.db.Exec(`UPDATE pets SET target_id=owner_id,phase='travel',revision=revision+1 WHERE owner_id=? AND (phase='travel' OR location_id!=owner_id)`, account)
	if e == nil {
		_, _ = r.store.db.Exec(`UPDATE visit_requests SET status='completed' WHERE guest_id=? AND status='accepted'`, account)
		_ = r.store.RevokeAvatarTasks(account, "AVATAR_TASK_REVOKED")
		for id, relay := range r.avatar {
			task, taskErr := r.store.AvatarTask(id)
			if taskErr == nil && task.OwnerID == account {
				delete(r.avatar, id)
			} else {
				r.avatar[id] = relay
			}
		}
	}
	return e
}

// Called under r.mu after a committed revocation.
func (r *SocialRuntime) dropRevokedAvatarRelays() {
	for id := range r.avatar {
		task, err := r.store.AvatarTask(id)
		if err != nil || task.State == AvatarRevoked {
			delete(r.avatar, id)
		}
	}
}
func (r *SocialRuntime) SendHome(host, guest string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	tx, e := r.store.db.Begin()
	if e != nil {
		return e
	}
	defer tx.Rollback()
	var location, target string
	if e = tx.QueryRow(`SELECT location_id,target_id FROM pets WHERE owner_id=?`, guest).Scan(&location, &target); e != nil || location != host && target != host {
		return ErrNotFound
	}
	if _, e = tx.Exec(`UPDATE pets SET target_id=owner_id,phase='travel',revision=revision+1 WHERE owner_id=?`, guest); e != nil {
		return e
	}
	if _, e = tx.Exec(`UPDATE visit_requests SET status='completed' WHERE guest_id=? AND host_id=? AND status='accepted'`, guest, host); e != nil {
		return e
	}
	if e = revokeRelationshipAvatarTasks(tx, host, guest); e != nil {
		return e
	}
	if e = tx.Commit(); e != nil {
		return e
	}
	r.dropRevokedAvatarRelays()
	return nil
}
func (r *SocialRuntime) SendAllHome(host string) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	tx, e := r.store.db.Begin()
	if e != nil {
		return e
	}
	defer tx.Rollback()
	rows, e := tx.Query(`SELECT owner_id FROM pets WHERE owner_id!=? AND (location_id=? OR target_id=?)`, host, host, host)
	if e != nil {
		return e
	}
	var guests []string
	for rows.Next() {
		var guest string
		if e = rows.Scan(&guest); e != nil {
			rows.Close()
			return e
		}
		guests = append(guests, guest)
	}
	e = rows.Err()
	rows.Close()
	if e != nil {
		return e
	}
	for _, guest := range guests {
		if e = revokeRelationshipAvatarTasks(tx, host, guest); e != nil {
			return e
		}
	}
	if _, e = tx.Exec(`UPDATE pets SET target_id=owner_id,phase='travel',revision=revision+1 WHERE owner_id!=? AND (location_id=? OR target_id=?)`, host, host, host); e != nil {
		return e
	}
	if _, e = tx.Exec(`UPDATE visit_requests SET status='completed' WHERE host_id=? AND status='accepted'`, host); e != nil {
		return e
	}
	if e = tx.Commit(); e != nil {
		return e
	}
	r.dropRevokedAvatarRelays()
	return nil
}
func (r *SocialRuntime) SetAccepting(account string, enabled bool) error {
	_, e := r.store.db.Exec(`UPDATE accounts SET accepting=? WHERE id=?`, enabled, account)
	if e == nil && !enabled {
		_, _ = r.store.db.Exec(`UPDATE visit_requests SET status='cancelled' WHERE host_id=? AND status='pending'`, account)
	}
	return e
}
