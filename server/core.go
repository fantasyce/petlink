package main

import (
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	_ "modernc.org/sqlite"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

const leaseDuration = 5 * time.Second

type User struct {
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	TokenHash string          `json:"token_hash"`
	PairHash  string          `json:"pair_hash,omitempty"`
	Paired    bool            `json:"paired"`
	Allows    map[string]bool `json:"allows"`
}
type Pet struct {
	Owner        string `json:"owner"`
	Name         string `json:"name"`
	Location     string `json:"location"`
	Target       string `json:"target"`
	Phase        string `json:"phase"`
	Revision     int64  `json:"revision"`
	LeaseUntil   int64  `json:"lease_until"`
	LeaseSession string `json:"lease_session"`
	Style        int    `json:"style"`
	Arrived      int64  `json:"arrived"`
	Wave         int64  `json:"wave"`
}
type State struct {
	Users map[string]*User `json:"users"`
	Pets  map[string]*Pet  `json:"pets"`
}
type session struct {
	ID   string
	Seen time.Time
}
type Hub struct {
	mu       sync.Mutex
	db       *sql.DB
	state    State
	sessions map[string]session
	now      func() time.Time
	readyAt  time.Time
	failed   error
}
type Command struct {
	ID       string `json:"id"`
	Action   string `json:"action"`
	Peer     string `json:"peer,omitempty"`
	Pet      string `json:"pet,omitempty"`
	Revision int64  `json:"revision,omitempty"`
	Enabled  bool   `json:"enabled"`
	Style    int    `json:"style,omitempty"`
}
type PublicPet struct {
	Owner    string `json:"owner"`
	Name     string `json:"name"`
	Location string `json:"location"`
	Target   string `json:"target"`
	Phase    string `json:"phase"`
	Revision int64  `json:"revision"`
	Style    int    `json:"style"`
	Wave     int64  `json:"wave"`
}
type Friend struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Online   bool   `json:"online"`
	Allowed  bool   `json:"allowed"`
	CanVisit bool   `json:"can_visit"`
}
type Hide struct {
	Pet      string `json:"pet"`
	Revision int64  `json:"revision"`
}
type Snapshot struct {
	ID      string      `json:"id"`
	Error   string      `json:"error"`
	Self    string      `json:"self"`
	Name    string      `json:"name"`
	Own     PublicPet   `json:"own"`
	Pets    []PublicPet `json:"pets"`
	Friends []Friend    `json:"friends"`
	Hides   []Hide      `json:"hides"`
	LeaseMS int         `json:"lease_ms"`
}

func digest(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }
func randomToken() string {
	b := make([]byte, 24)
	if _, e := rand.Read(b); e != nil {
		panic(e)
	}
	return hex.EncodeToString(b)
}
func OpenHub(path string) (*Hub, error) {
	if e := os.MkdirAll(filepath.Dir(path), 0700); e != nil {
		return nil, e
	}
	db, e := sql.Open("sqlite", path)
	if e != nil {
		return nil, e
	}
	db.SetMaxOpenConns(1)
	if _, e = db.Exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000; CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), body TEXT NOT NULL)"); e != nil {
		db.Close()
		return nil, e
	}
	if e = os.Chmod(path, 0600); e != nil {
		db.Close()
		return nil, e
	}
	h := &Hub{db: db, state: State{map[string]*User{}, map[string]*Pet{}}, sessions: map[string]session{}, now: time.Now, readyAt: time.Now().Add(6 * time.Second)}
	var raw string
	e = db.QueryRow("SELECT body FROM state WHERE id=1").Scan(&raw)
	if e != nil && e != sql.ErrNoRows {
		db.Close()
		return nil, e
	}
	if raw != "" {
		if e = json.Unmarshal([]byte(raw), &h.state); e != nil {
			db.Close()
			return nil, e
		}
	}
	return h, nil
}
func (h *Hub) Close() { h.db.Close() }
func (h *Hub) Health() error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.failed != nil {
		return h.failed
	}
	return h.db.Ping()
}
func (h *Hub) save() error {
	b, e := json.Marshal(h.state)
	if e == nil {
		_, e = h.db.Exec("INSERT INTO state(id,body) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body", string(b))
	}
	if e != nil {
		h.failed = e
	}
	return e
}
func (h *Hub) AddUser(id, name, token string) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.state.Users[id] != nil {
		return errors.New("identity already exists")
	}
	h.state.Users[id] = &User{ID: id, Name: name, TokenHash: digest(token), Allows: map[string]bool{}}
	h.state.Pets[id] = &Pet{Owner: id, Name: name + "的小伙伴", Location: id, Phase: "home", Revision: 1}
	return h.save()
}
func (h *Hub) AddInvitation(id, name, code string) error {
	if e := h.AddUser(id, name, randomToken()); e != nil {
		return e
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.state.Users[id].PairHash = digest(code)
	return h.save()
}
func (h *Hub) Pair(code string) (string, string, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, u := range h.state.Users {
		if u.PairHash == digest(code) && !u.Paired {
			token := randomToken()
			u.TokenHash = digest(token)
			u.PairHash = ""
			u.Paired = true
			if e := h.save(); e != nil {
				return "", "", e
			}
			return u.ID, token, nil
		}
	}
	return "", "", errors.New("配对码无效或已使用")
}
func (h *Hub) Auth(token string) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	if token == "" || h.failed != nil {
		return ""
	}
	for id, u := range h.state.Users {
		if u.TokenHash == digest(token) {
			return id
		}
	}
	return ""
}
func (h *Hub) Connect(id, sid string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.sessions[id] = session{sid, h.now()}
}
func (h *Hub) Disconnect(id, sid string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.sessions[id].ID == sid {
		delete(h.sessions, id)
	}
}
func (h *Hub) online(id string) bool {
	s, ok := h.sessions[id]
	return ok && h.now().Sub(s.Seen) < 10*time.Second
}
func (h *Hub) transfer(p *Pet, target string) { p.Target = target; p.Phase = "travel"; p.Revision++ }
func (h *Hub) tick() {
	if h.now().Before(h.readyAt) {
		return
	}
	now := h.now().UnixMilli()
	for _, p := range h.state.Pets {
		if p.Phase == "travel" && p.Target != p.Owner && (!h.online(p.Target) || !h.state.Users[p.Target].Allows[p.Owner]) {
			p.Target = p.Owner
			p.Revision++
		}
		if p.Phase != "travel" && p.Location != p.Owner && (!h.online(p.Location) || !h.state.Users[p.Location].Allows[p.Owner] || now-p.Arrived > 15*60*1000) {
			h.transfer(p, p.Owner)
		}
		if p.Phase == "travel" && p.LeaseUntil <= now {
			p.Location = p.Target
			p.Target = ""
			p.LeaseSession = ""
			p.LeaseUntil = 0
			p.Revision++
			p.Arrived = now
			p.Phase = "visit"
			if p.Location == p.Owner {
				p.Phase = "home"
			}
		}
	}
}
func (h *Hub) Act(id, sid string, c Command) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.failed != nil {
		return errors.New("存储不可用")
	}
	if h.sessions[id].ID != sid || h.state.Users[id] == nil {
		return errors.New("连接已失效")
	}
	h.sessions[id] = session{sid, h.now()}
	h.tick()
	p := h.state.Pets[id]
	switch c.Action {
	case "sync":
	case "allow":
		if c.Peer == id || h.state.Users[c.Peer] == nil {
			return errors.New("好友不存在")
		}
		h.state.Users[id].Allows[c.Peer] = c.Enabled
		h.tick()
	case "visit":
		if c.Peer == id || h.state.Users[c.Peer] == nil || !h.state.Users[c.Peer].Allows[id] {
			return errors.New("对方尚未授权你来访")
		}
		if !h.online(c.Peer) {
			return errors.New("对方当前离线")
		}
		if p.Phase != "home" {
			return errors.New("桌宠已经外出或正在旅途中")
		}
		for _, other := range h.state.Pets {
			if other.Owner != c.Peer && (other.Location == c.Peer || other.Target == c.Peer) {
				return errors.New("对方正在接待其他访客")
			}
		}
		h.transfer(p, c.Peer)
	case "recall":
		if p.Phase == "travel" {
			p.Target = id
			p.Revision++
		} else if p.Location != id {
			h.transfer(p, id)
		}
	case "send_home":
		guest := h.state.Pets[c.Pet]
		if guest == nil || guest.Owner == id || guest.Location != id {
			return errors.New("访客不存在")
		}
		h.transfer(guest, guest.Owner)
	case "ack":
		pet := h.state.Pets[c.Pet]
		if pet == nil || pet.Phase != "travel" || pet.Location != id || pet.Revision != c.Revision || pet.LeaseSession != sid {
			return errors.New("过期的离场确认")
		}
		pet.LeaseUntil = 0
		pet.LeaseSession = ""
	case "style":
		if c.Style < 0 || c.Style > 1 {
			return errors.New("装扮不存在")
		}
		p.Style = c.Style
	case "wave":
		p.Wave++
		if p.Wave > 1_000_000 {
			p.Wave = 1
		}
	default:
		return errors.New("未知操作")
	}
	h.tick()
	return h.save()
}
func public(p *Pet) PublicPet {
	return PublicPet{p.Owner, p.Name, p.Location, p.Target, p.Phase, p.Revision, p.Style, p.Wave}
}
func (h *Hub) Snapshot(id, sid string) Snapshot {
	h.mu.Lock()
	defer h.mu.Unlock()
	s := Snapshot{Self: id, Pets: []PublicPet{}, Friends: []Friend{}, Hides: []Hide{}, LeaseMS: 3000}
	u := h.state.Users[id]
	if u == nil || h.sessions[id].ID != sid || h.failed != nil {
		s.Error = "连接或存储已失效"
		return s
	}
	h.sessions[id] = session{sid, h.now()}
	h.tick()
	s.Name = u.Name
	s.Own = public(h.state.Pets[id])
	for fid, f := range h.state.Users {
		if fid != id {
			s.Friends = append(s.Friends, Friend{fid, f.Name, h.online(fid), u.Allows[fid], f.Allows[id]})
		}
	}
	sort.Slice(s.Friends, func(i, j int) bool { return s.Friends[i].ID < s.Friends[j].ID })
	if !h.now().Before(h.readyAt) {
		for _, p := range h.state.Pets {
			if p.Location == id {
				if p.Phase == "travel" {
					if p.LeaseSession == sid {
						s.Hides = append(s.Hides, Hide{p.Owner, p.Revision})
					}
					continue
				}
				if p.LeaseUntil > h.now().UnixMilli() && p.LeaseSession != sid {
					continue
				}
				p.LeaseSession = sid
				p.LeaseUntil = h.now().Add(leaseDuration).UnixMilli()
				s.Pets = append(s.Pets, public(p))
			}
		}
	}
	sort.Slice(s.Pets, func(i, j int) bool { return s.Pets[i].Owner < s.Pets[j].Owner })
	if e := h.save(); e != nil {
		s.Pets = []PublicPet{}
		s.Error = fmt.Sprint("存储失败")
	}
	return s
}
