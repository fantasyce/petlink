package main

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

var (
	ErrGoogleUnavailable     = errors.New("GOOGLE_UNAVAILABLE")
	ErrGoogleIdentityInvalid = errors.New("GOOGLE_IDENTITY_INVALID")
)

type GoogleConfig struct{ ClientID, ClientSecret string }
type GoogleIdentity struct{ Issuer, Subject, Email string }
type GoogleExchangeInput struct{ Code, Verifier, RedirectURI, Nonce string }

// GoogleProvider never exposes upstream responses, authorization codes or tokens
// to callers. Only the verified minimal identity crosses this boundary.
type GoogleProvider struct {
	config               GoogleConfig
	client               *http.Client
	tokenURL, keysURL    string
	now                  func() time.Time
	slots                chan struct{}
	mu                   sync.Mutex
	keys                 map[string]*rsa.PublicKey
	expires, lastRefresh time.Time
}

func NewGoogleProvider(config GoogleConfig) (*GoogleProvider, error) {
	if strings.TrimSpace(config.ClientID) == "" {
		return nil, ErrGoogleUnavailable
	}
	return newGoogleProvider(config, &http.Client{}, "https://oauth2.googleapis.com/token", "https://www.googleapis.com/oauth2/v3/certs", time.Now), nil
}
func newGoogleProvider(config GoogleConfig, client *http.Client, tokenURL, keysURL string, now func() time.Time) *GoogleProvider {
	c := *client
	c.Timeout = 10 * time.Second
	c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return &GoogleProvider{config: config, client: &c, tokenURL: tokenURL, keysURL: keysURL, now: now, slots: make(chan struct{}, 2), keys: map[string]*rsa.PublicKey{}}
}
func (p *GoogleProvider) Exchange(ctx context.Context, in GoogleExchangeInput) (GoogleIdentity, error) {
	empty := GoogleIdentity{}
	if in.Code == "" || len(in.Code) > 8192 || in.Verifier == "" || len(in.Verifier) > 128 || in.Nonce == "" || len(in.RedirectURI) > 1024 {
		return empty, ErrGoogleIdentityInvalid
	}
	select {
	case p.slots <- struct{}{}:
		defer func() { <-p.slots }()
	default:
		return empty, ErrAuthRateLimited
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	form := url.Values{"client_id": {p.config.ClientID}, "grant_type": {"authorization_code"}, "code": {in.Code}, "code_verifier": {in.Verifier}, "redirect_uri": {in.RedirectURI}}
	if p.config.ClientSecret != "" {
		form.Set("client_secret", p.config.ClientSecret)
	}
	req, e := http.NewRequestWithContext(ctx, http.MethodPost, p.tokenURL, strings.NewReader(form.Encode()))
	if e != nil {
		return empty, ErrGoogleUnavailable
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	resp, e := p.client.Do(req)
	if e != nil {
		return empty, ErrGoogleUnavailable
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return empty, ErrGoogleUnavailable
	}
	raw, e := io.ReadAll(io.LimitReader(resp.Body, 65537))
	if e != nil || len(raw) > 65536 {
		return empty, ErrGoogleUnavailable
	}
	var data struct {
		IDToken string `json:"id_token"`
	}
	if json.Unmarshal(raw, &data) != nil || data.IDToken == "" {
		return empty, ErrGoogleIdentityInvalid
	}
	return p.verify(ctx, data.IDToken, in.Nonce)
}

type googleClaims struct {
	jwt.RegisteredClaims
	Nonce           string `json:"nonce"`
	Email           string `json:"email"`
	EmailVerified   bool   `json:"email_verified"`
	AuthorizedParty string `json:"azp"`
}

func (p *GoogleProvider) verify(ctx context.Context, raw, nonce string) (GoogleIdentity, error) {
	var c googleClaims
	_, e := jwt.ParseWithClaims(raw, &c, func(t *jwt.Token) (any, error) {
		kid, ok := t.Header["kid"].(string)
		if !ok || kid == "" || len(kid) > 256 {
			return nil, ErrGoogleIdentityInvalid
		}
		return p.key(ctx, kid)
	}, jwt.WithValidMethods([]string{"RS256"}), jwt.WithAudience(p.config.ClientID), jwt.WithExpirationRequired(), jwt.WithIssuedAt(), jwt.WithLeeway(60*time.Second), jwt.WithTimeFunc(p.now))
	if e != nil {
		return GoogleIdentity{}, ErrGoogleIdentityInvalid
	}
	if (c.Issuer != "https://accounts.google.com" && c.Issuer != "accounts.google.com") || c.Subject == "" || len(c.Subject) > 255 || c.IssuedAt == nil || c.ExpiresAt == nil || !c.EmailVerified || c.Email == "" || len(c.Email) > 320 || c.Nonce != nonce || nonce == "" {
		return GoogleIdentity{}, ErrGoogleIdentityInvalid
	}
	if (c.AuthorizedParty != "" && c.AuthorizedParty != p.config.ClientID) || (len(c.Audience) > 1 && c.AuthorizedParty == "") {
		return GoogleIdentity{}, ErrGoogleIdentityInvalid
	}
	return GoogleIdentity{Issuer: "https://accounts.google.com", Subject: c.Subject, Email: c.Email}, nil
}
func (p *GoogleProvider) key(ctx context.Context, kid string) (*rsa.PublicKey, error) {
	// Single-flight under a provider-local lock. No store/runtime lock is held.
	p.mu.Lock()
	defer p.mu.Unlock()
	now := p.now()
	if key := p.keys[kid]; key != nil && now.Before(p.expires) {
		return key, nil
	}
	if !p.lastRefresh.IsZero() && now.Sub(p.lastRefresh) < 30*time.Second {
		return nil, ErrGoogleIdentityInvalid
	}
	p.lastRefresh = now
	req, e := http.NewRequestWithContext(ctx, http.MethodGet, p.keysURL, nil)
	if e != nil {
		return nil, ErrGoogleUnavailable
	}
	resp, e := p.client.Do(req)
	if e != nil {
		return nil, ErrGoogleUnavailable
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, ErrGoogleUnavailable
	}
	raw, e := io.ReadAll(io.LimitReader(resp.Body, (1<<20)+1))
	if e != nil || len(raw) > 1<<20 {
		return nil, ErrGoogleUnavailable
	}
	var set struct {
		Keys []struct{ Kty, Use, Alg, Kid, N, E string }
	}
	if json.Unmarshal(raw, &set) != nil || len(set.Keys) == 0 || len(set.Keys) > 16 {
		return nil, ErrGoogleUnavailable
	}
	keys := make(map[string]*rsa.PublicKey)
	for _, j := range set.Keys {
		if j.Kty != "RSA" || j.Use != "sig" || (j.Alg != "" && j.Alg != "RS256") || j.Kid == "" || len(j.Kid) > 256 {
			continue
		}
		nb, ne := base64.RawURLEncoding.DecodeString(j.N)
		eb, ee := base64.RawURLEncoding.DecodeString(j.E)
		if ne != nil || ee != nil || len(nb) < 256 || len(nb) > 1024 || len(eb) == 0 || len(eb) > 4 {
			continue
		}
		n := new(big.Int).SetBytes(nb)
		exp := new(big.Int).SetBytes(eb).Int64()
		if n.BitLen() < 2048 || exp < 3 || exp > 2147483647 || exp%2 == 0 {
			continue
		}
		if keys[j.Kid] != nil {
			return nil, ErrGoogleUnavailable
		}
		keys[j.Kid] = &rsa.PublicKey{N: n, E: int(exp)}
	}
	if len(keys) == 0 {
		return nil, ErrGoogleUnavailable
	}
	ttl := time.Hour
	for _, part := range strings.Split(resp.Header.Get("Cache-Control"), ",") {
		part = strings.TrimSpace(part)
		if part == "no-cache" || part == "no-store" {
			ttl = 0
		}
		if strings.HasPrefix(part, "max-age=") {
			if n, e := strconv.ParseInt(strings.Trim(strings.TrimPrefix(part, "max-age="), "\""), 10, 32); e == nil && n >= 0 && time.Duration(n)*time.Second < ttl {
				ttl = time.Duration(n) * time.Second
			}
		}
	}
	p.keys = keys
	p.expires = now.Add(ttl)
	if keys[kid] == nil {
		return nil, ErrGoogleIdentityInvalid
	}
	return keys[kid], nil
}
