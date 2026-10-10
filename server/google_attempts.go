package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	ErrGoogleExpired   = errors.New("GOOGLE_LOGIN_EXPIRED")
	ErrAuthAttemptUsed = errors.New("AUTH_ATTEMPT_USED")
	ErrAuthRateLimited = errors.New("AUTH_RATE_LIMITED")
)

type GoogleAttemptInput struct {
	DeviceID    string `json:"device_id"`
	Challenge   string `json:"challenge"`
	RedirectURI string `json:"redirect_uri"`
	Mode        string `json:"mode"`
	RequestID   string `json:"-"`
}
type GoogleProof struct{ AccountID, SessionID, RecoveryHash, PasswordHash string }
type GoogleAttemptResult struct {
	AttemptToken string    `json:"attempt_token"`
	Nonce        string    `json:"nonce"`
	ClientID     string    `json:"client_id"`
	ExpiresAt    time.Time `json:"expires_at"`
}
type GoogleAttempt struct {
	GoogleAttemptInput
	Nonce     string
	Proof     *GoogleProof
	ExpiresAt time.Time
	used      bool
}
type googleRate struct {
	Start time.Time
	Count int
}
type GoogleTicket struct {
	Kind, DeviceID, AccountID string
	Proof                     *GoogleProof
	Identity                  GoogleIdentity
	ExpiresAt                 time.Time
}
type GoogleAttempts struct {
	mu       sync.Mutex
	clientID string
	now      func() time.Time
	attempts map[string]GoogleAttempt
	rates    map[string]googleRate
	tickets  map[string]GoogleTicket
}

func newGoogleAttempts(clientID string, now func() time.Time) *GoogleAttempts {
	return &GoogleAttempts{clientID: clientID, now: now, attempts: map[string]GoogleAttempt{}, rates: map[string]googleRate{}, tickets: map[string]GoogleTicket{}}
}
func googleRandom() (string, error) {
	var b [32]byte
	if _, e := rand.Read(b[:]); e != nil {
		return "", e
	}
	return base64.RawURLEncoding.EncodeToString(b[:]), nil
}
func (a *GoogleAttempts) sweep(now time.Time) {
	for k, v := range a.attempts {
		if !now.Before(v.ExpiresAt) {
			delete(a.attempts, k)
		}
	}
	for k, v := range a.tickets {
		if !now.Before(v.ExpiresAt) {
			delete(a.tickets, k)
		}
	}
	for k, v := range a.rates {
		if now.Sub(v.Start) >= time.Minute {
			delete(a.rates, k)
		}
	}
}

var googleCallbackPath = regexp.MustCompile(`^/callback/[A-Za-z0-9_-]{22,128}$`)
var googleVerifierPattern = regexp.MustCompile(`^[A-Za-z0-9._~-]{43,128}$`)

func validGoogleRedirect(raw string) bool {
	if len(raw) > 1024 {
		return false
	}
	u, e := url.Parse(raw)
	if e != nil || u.Scheme != "http" || u.Hostname() != "127.0.0.1" || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || u.RawPath != "" || !googleCallbackPath.MatchString(u.Path) {
		return false
	}
	p, e := strconv.Atoi(u.Port())
	return e == nil && p > 0 && p <= 65535 && u.Host == "127.0.0.1:"+strconv.Itoa(p)
}
func (a *GoogleAttempts) Begin(ip string, in GoogleAttemptInput, proof *GoogleProof) (GoogleAttemptResult, error) {
	empty := GoogleAttemptResult{}
	b, e := base64.RawURLEncoding.DecodeString(in.Challenge)
	if ip == "" || len(ip) > 64 || in.DeviceID == "" || len(in.DeviceID) > 128 || in.RequestID == "" || len(in.RequestID) > 128 || e != nil || len(b) != 32 || base64.RawURLEncoding.EncodeToString(b) != in.Challenge || !validGoogleRedirect(in.RedirectURI) || (in.Mode != "login" && in.Mode != "link") || (in.Mode == "link" && (proof == nil || proof.AccountID == "")) {
		return empty, ErrValidation
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	now := a.now()
	a.sweep(now)
	rate, exists := a.rates[ip]
	if rate.Count >= 10 || (!exists && len(a.rates) >= 200) || len(a.attempts) >= 200 {
		return empty, ErrAuthRateLimited
	}
	if !exists {
		rate.Start = now
	}
	rate.Count++
	a.rates[ip] = rate
	token, e := googleRandom()
	if e != nil {
		return empty, ErrGoogleUnavailable
	}
	nonce, e := googleRandom()
	if e != nil {
		return empty, ErrGoogleUnavailable
	}
	var saved *GoogleProof
	if proof != nil {
		copy := *proof
		saved = &copy
	}
	expires := now.Add(5 * time.Minute)
	a.attempts[hashValue(token)] = GoogleAttempt{GoogleAttemptInput: in, Nonce: nonce, Proof: saved, ExpiresAt: expires}
	return GoogleAttemptResult{AttemptToken: token, Nonce: nonce, ClientID: a.clientID, ExpiresAt: expires}, nil
}
func (a *GoogleAttempts) Claim(token, verifier string) (GoogleAttempt, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.sweep(a.now())
	empty := GoogleAttempt{}
	if len(token) > 128 || !googleVerifierPattern.MatchString(verifier) {
		return empty, ErrGoogleIdentityInvalid
	}
	key := hashValue(token)
	v, ok := a.attempts[key]
	if !ok {
		return empty, ErrGoogleExpired
	}
	if v.used {
		return empty, ErrAuthAttemptUsed
	}
	digest := sha256.Sum256([]byte(verifier))
	want := base64.RawURLEncoding.EncodeToString(digest[:])
	if subtle.ConstantTimeCompare([]byte(want), []byte(v.Challenge)) != 1 {
		return empty, ErrGoogleIdentityInvalid
	}
	v.used = true
	a.attempts[key] = v
	return v, nil
}
func (a *GoogleAttempts) Cancel(token string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.sweep(a.now())
	if len(token) > 128 {
		return ErrGoogleExpired
	}
	key := hashValue(token)
	v, ok := a.attempts[key]
	if !ok {
		return ErrGoogleExpired
	}
	if v.used {
		return ErrAuthAttemptUsed
	}
	delete(a.attempts, key)
	return nil
}
func (a *GoogleAttempts) IssueTicket(v GoogleTicket) (string, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := a.now()
	a.sweep(now)
	if len(a.tickets) >= 200 {
		return "", ErrAuthRateLimited
	}
	if v.DeviceID == "" || len(v.DeviceID) > 128 || v.AccountID == "" || !strings.Contains("|link|takeover|migration|", "|"+v.Kind+"|") || v.Kind == "" {
		return "", ErrValidation
	}
	ttl := 5 * time.Minute
	if v.Kind == "takeover" {
		ttl = time.Minute
	}
	v.ExpiresAt = now.Add(ttl)
	if v.Proof != nil {
		copy := *v.Proof
		v.Proof = &copy
	}
	token, e := googleRandom()
	if e != nil {
		return "", ErrGoogleUnavailable
	}
	a.tickets[hashValue(token)] = v
	return token, nil
}
func (a *GoogleAttempts) TakeTicket(token, kind, device string) (GoogleTicket, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.sweep(a.now())
	empty := GoogleTicket{}
	if len(token) > 128 {
		return empty, ErrGoogleExpired
	}
	key := hashValue(token)
	v, ok := a.tickets[key]
	if !ok {
		return empty, ErrGoogleExpired
	}
	if v.Kind != kind || v.DeviceID != device {
		return empty, ErrUnauthorized
	}
	delete(a.tickets, key)
	return v, nil
}

func (a *GoogleAttempts) AllowProof(ip string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	now := a.now()
	a.sweep(now)
	rate, exists := a.rates[ip]
	if rate.Count >= 10 || (!exists && len(a.rates) >= 200) {
		return ErrAuthRateLimited
	}
	if !exists {
		rate.Start = now
	}
	rate.Count++
	a.rates[ip] = rate
	return nil
}
