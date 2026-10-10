package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

// Only Google's external HTTP boundary is substituted. Signing, parsing,
// signature verification and claim validation exercise production code.
type googleProviderFixture struct {
	p            *GoogleProvider
	key          *rsa.PrivateKey
	claims       jwt.MapClaims
	now          time.Time
	token        string
	kid          string
	requests     atomic.Int32
	tokenHandler func(http.ResponseWriter, *http.Request)
}

func newGoogleProviderFixture(t *testing.T) *googleProviderFixture {
	t.Helper()
	key, e := rsa.GenerateKey(rand.Reader, 2048)
	if e != nil {
		t.Fatal(e)
	}
	f := &googleProviderFixture{key: key, now: time.Now().Truncate(time.Second), kid: "one"}
	f.claims = jwt.MapClaims{"iss": "https://accounts.google.com", "sub": "fixture-subject", "aud": "fixture-client", "iat": f.now.Unix(), "exp": f.now.Add(time.Hour).Unix(), "nonce": "fixture-nonce", "email": "person@example.invalid", "email_verified": true}
	mux := http.NewServeMux()
	mux.HandleFunc("/keys", func(w http.ResponseWriter, r *http.Request) {
		f.requests.Add(1)
		w.Header().Set("Cache-Control", "public, max-age=120")
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []any{map[string]string{"kty": "RSA", "use": "sig", "alg": "RS256", "kid": f.kid, "n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()), "e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes())}}})
	})
	mux.HandleFunc("/token", func(w http.ResponseWriter, r *http.Request) {
		if f.tokenHandler != nil {
			f.tokenHandler(w, r)
			return
		}
		if r.Method != "POST" {
			t.Error("not POST")
		}
		_ = r.ParseForm()
		for k, v := range map[string]string{"client_id": "fixture-client", "code": "fixture-code", "code_verifier": "fixture-verifier", "redirect_uri": "http://127.0.0.1:12345/callback", "grant_type": "authorization_code"} {
			if r.Form.Get(k) != v {
				t.Errorf("wrong exchange field %s", k)
			}
		}
		_ = json.NewEncoder(w).Encode(map[string]string{"id_token": f.token, "access_token": "discard-me"})
	})
	s := httptest.NewServer(mux)
	t.Cleanup(s.Close)
	f.p = newGoogleProvider(GoogleConfig{ClientID: "fixture-client"}, s.Client(), s.URL+"/token", s.URL+"/keys", func() time.Time { return f.now })
	return f
}
func (f *googleProviderFixture) sign(t *testing.T, kid string) {
	t.Helper()
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, f.claims)
	tok.Header["kid"] = kid
	var e error
	f.token, e = tok.SignedString(f.key)
	if e != nil {
		t.Fatal(e)
	}
}
func (f *googleProviderFixture) exchange() (GoogleIdentity, error) {
	return f.p.Exchange(context.Background(), GoogleExchangeInput{Code: "fixture-code", Verifier: "fixture-verifier", RedirectURI: "http://127.0.0.1:12345/callback", Nonce: "fixture-nonce"})
}

func TestGoogleProviderSaturationHTTPError(t *testing.T) {
	f := newGoogleProviderFixture(t)
	f.p.slots <- struct{}{}
	f.p.slots <- struct{}{}
	_, err := f.exchange()
	w := httptest.NewRecorder()
	googleError(w, err)
	if w.Code != http.StatusTooManyRequests || !strings.Contains(w.Body.String(), "AUTH_RATE_LIMITED") {
		t.Fatalf("saturation: %d %s", w.Code, w.Body.String())
	}
}

func TestGoogleProviderClaims(t *testing.T) {
	f := newGoogleProviderFixture(t)
	cases := []struct {
		name, key string
		value     any
		remove    bool
	}{
		{"issuer", "iss", "https://attacker.invalid", false}, {"audience", "aud", "other", false}, {"azp", "azp", "other", false},
		{"multipleAudWithoutAzp", "aud", []string{"fixture-client", "other"}, false},
		{"emptySubject", "sub", "", false}, {"nonce", "nonce", "other", false}, {"unverifiedEmail", "email_verified", false, false},
		{"missingEmail", "email", nil, true}, {"expiry", "exp", f.now.Add(-61 * time.Second).Unix(), false},
		{"futureIssued", "iat", f.now.Add(61 * time.Second).Unix(), false}, {"missingIssued", "iat", nil, true}, {"missingExpiry", "exp", nil, true},
	}
	f.sign(t, "one")
	got, e := f.exchange()
	if e != nil || got.Subject != "fixture-subject" || got.Issuer != "https://accounts.google.com" {
		t.Fatalf("valid identity: %+v %v", got, e)
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			old, exists := f.claims[tc.key]
			if tc.remove {
				delete(f.claims, tc.key)
			} else {
				f.claims[tc.key] = tc.value
			}
			defer func() {
				if exists {
					f.claims[tc.key] = old
				} else {
					delete(f.claims, tc.key)
				}
			}()
			f.sign(t, "one")
			if _, e := f.exchange(); !errors.Is(e, ErrGoogleIdentityInvalid) {
				t.Fatalf("wanted invalid identity, got %v", e)
			}
		})
	}
	f.claims["iss"] = "accounts.google.com"
	f.sign(t, "one")
	if got, e = f.exchange(); e != nil || got.Issuer != "https://accounts.google.com" {
		t.Fatal("Google issuer normalization", e)
	}
	f.token = "eyJhbGciOiJub25lIn0.e30."
	if _, e = f.exchange(); !errors.Is(e, ErrGoogleIdentityInvalid) {
		t.Fatal("accepted unsigned JWT", e)
	}
}
func TestGoogleProviderExchange(t *testing.T) {
	f := newGoogleProviderFixture(t)
	f.sign(t, "one")
	if _, e := f.exchange(); e != nil {
		t.Fatal(e)
	}
	f.tokenHandler = func(w http.ResponseWriter, r *http.Request) { http.Error(w, "private-google-response", 400) }
	if _, e := f.exchange(); e == nil || strings.Contains(e.Error(), "private-google") {
		t.Fatal("unsafe provider error", e)
	}
	f.tokenHandler = func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Location", "https://attacker.invalid")
		w.WriteHeader(307)
	}
	if _, e := f.exchange(); e == nil {
		t.Fatal("accepted redirect")
	}
	release := make(chan struct{})
	defer close(release)
	f.tokenHandler = func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
		case <-release:
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, e := f.p.Exchange(ctx, GoogleExchangeInput{Code: "fixture-code", Verifier: "fixture-verifier", RedirectURI: "http://127.0.0.1:12345/callback", Nonce: "fixture-nonce"})
	if e == nil || time.Since(start) > time.Second {
		t.Fatal("cancellation failed", e)
	}
}
func TestGoogleProviderKeyRotation(t *testing.T) {
	f := newGoogleProviderFixture(t)
	f.sign(t, "one")
	if _, e := f.exchange(); e != nil {
		t.Fatal(e)
	}
	if _, e := f.exchange(); e != nil || f.requests.Load() != 1 {
		t.Fatal("cache not reused", e)
	}
	f.now = f.now.Add(31 * time.Second)
	f.kid = "two"
	f.sign(t, "two")
	if _, e := f.exchange(); e != nil || f.requests.Load() != 2 {
		t.Fatal("rotation not refreshed", e)
	}
	for i := 0; i < 10; i++ {
		f.sign(t, "unknown")
		if _, e := f.exchange(); e == nil {
			t.Fatal("unknown accepted")
		}
	}
	if f.requests.Load() != 2 {
		t.Fatal("unknown kid bypassed cooldown")
	}
	f.now = f.now.Add(121 * time.Second)
	f.sign(t, "two")
	if _, e := f.exchange(); e != nil || f.requests.Load() != 3 {
		t.Fatal("expired cache", e)
	}
}

func TestGoogleProviderRejectsForgedSignatureAndHeaderURL(t *testing.T) {
	f := newGoogleProviderFixture(t)
	other, e := rsa.GenerateKey(rand.Reader, 2048)
	if e != nil {
		t.Fatal(e)
	}
	var calls atomic.Int32
	trap := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { calls.Add(1) }))
	defer trap.Close()
	tok := jwt.NewWithClaims(jwt.SigningMethodRS256, f.claims)
	tok.Header["kid"] = "one"
	tok.Header["jku"] = trap.URL
	f.token, e = tok.SignedString(other)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = f.exchange(); !errors.Is(e, ErrGoogleIdentityInvalid) {
		t.Fatal("forged signature accepted", e)
	}
	if calls.Load() != 0 {
		t.Fatal("fetched token-supplied URL")
	}
	f.sign(t, "one")
	if _, e = f.exchange(); e != nil {
		t.Fatal(e)
	}
	f.now = f.now.Add(121 * time.Second)
	f.p.keysURL = trap.URL
	if _, e = f.exchange(); e == nil {
		t.Fatal("expired cached key trusted after malformed refresh")
	}
}
