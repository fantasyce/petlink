package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

type googleExchanger interface {
	Exchange(context.Context, GoogleExchangeInput) (GoogleIdentity, error)
}
type GoogleAuthService struct {
	Store         *SocialStore
	Runtime       *SocialRuntime
	Attempts      *GoogleAttempts
	Provider      googleExchanger
	MigrationOpen bool
}

func googleClientIP(r *http.Request) string {
	host, _, e := net.SplitHostPort(r.RemoteAddr)
	if e != nil {
		return "unknown"
	}
	return host
}
func googleError(w http.ResponseWriter, e error) {
	code := "AUTH_FAILED"
	status := 400
	switch e {
	case ErrGoogleUnavailable:
		code = e.Error()
		status = 503
	case ErrGoogleIdentityInvalid, ErrUnauthorized:
		code = e.Error()
		status = 401
	case ErrGoogleExpired:
		code = e.Error()
		status = 410
	case ErrAuthRateLimited:
		code = e.Error()
		status = 429
	case ErrAuthAttemptUsed, ErrGoogleAlreadyLinked, ErrAccountAlreadyLinked:
		code = e.Error()
		status = 409
	case ErrMigrationClosed, ErrMigrationRequired, ErrValidation:
		code = e.Error()
	}
	writeJSON(w, status, apiError{code, code})
}

// Duplicate keys and trailing JSON are rejected before typed decoding.
func googleDecode(w http.ResponseWriter, r *http.Request, out any) bool {
	if r.Method != "POST" {
		w.WriteHeader(405)
		return false
	}
	ids := r.Header.Values("X-Request-ID")
	if len(ids) != 1 || strings.TrimSpace(ids[0]) == "" || len(ids[0]) > 128 {
		googleError(w, ErrValidation)
		return false
	}
	raw, e := io.ReadAll(http.MaxBytesReader(w, r.Body, 16<<10))
	if e != nil {
		googleError(w, ErrValidation)
		return false
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	tok, e := d.Token()
	if e != nil || tok != json.Delim('{') {
		googleError(w, ErrValidation)
		return false
	}
	seen := map[string]bool{}
	for d.More() {
		tok, e = d.Token()
		k, ok := tok.(string)
		if e != nil || !ok || seen[k] {
			googleError(w, ErrValidation)
			return false
		}
		seen[k] = true
		var value json.RawMessage
		if d.Decode(&value) != nil {
			googleError(w, ErrValidation)
			return false
		}
	}
	if _, e = d.Token(); e != nil {
		googleError(w, ErrValidation)
		return false
	}
	if _, e = d.Token(); !errors.Is(e, io.EOF) {
		googleError(w, ErrValidation)
		return false
	}
	d = json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(out) != nil {
		googleError(w, ErrValidation)
		return false
	}
	return true
}
func GoogleHandler(a *GoogleAuthService) http.Handler {
	a.Store.googleOnly.Store(true)
	mux := http.NewServeMux()
	RegisterGoogleRoutes(mux, a)
	legacy := SocialHandlerWithRuntime(a.Store, a.Runtime)
	mux.Handle("/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v2/auth/register", "/v2/auth/login", "/v2/auth/recover", "/v2/auth/claim", "/v2/auth/takeover":
			writeJSON(w, 426, apiError{"CLIENT_UPGRADE_REQUIRED", "CLIENT_UPGRADE_REQUIRED"})
			return
		}
		legacy.ServeHTTP(w, r)
	}))
	return mux
}
func RegisterGoogleRoutes(mux *http.ServeMux, a *GoogleAuthService) {
	mux.HandleFunc("/v2/auth/config", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			w.WriteHeader(405)
			return
		}
		writeJSON(w, 200, map[string]any{"mode": "google", "client_id": a.Attempts.clientID, "migration_open": a.MigrationOpen, "auth_protocol": 1})
	})
	mux.HandleFunc("/v2/auth/migration/prove", func(w http.ResponseWriter, r *http.Request) {
		if !a.MigrationOpen {
			googleError(w, ErrMigrationClosed)
			return
		}
		var in struct {
			Username     string `json:"username"`
			Password     string `json:"password"`
			RecoveryCode string `json:"recovery_code"`
			DeviceID     string `json:"device_id"`
		}
		if !googleDecode(w, r, &in) {
			return
		}
		if e := a.Attempts.AllowProof(googleClientIP(r)); e != nil {
			googleError(w, e)
			return
		}
		p, e := a.Store.ProveLegacy(in.Username, in.Password, in.RecoveryCode)
		if e != nil {
			googleError(w, e)
			return
		}
		ticket, e := a.Attempts.IssueTicket(GoogleTicket{Kind: "migration", DeviceID: in.DeviceID, AccountID: p.AccountID, Proof: &p})
		if e != nil {
			googleError(w, e)
			return
		}
		profile, e := a.Store.Profile(p.AccountID)
		if e != nil {
			googleError(w, e)
			return
		}
		writeJSON(w, 200, map[string]any{"ticket": ticket, "nickname": profile.Nickname, "friend_id": profile.FriendID})
	})
	mux.HandleFunc("/v2/auth/google/begin", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			GoogleAttemptInput
			MigrationTicket string `json:"migration_ticket"`
		}
		if !googleDecode(w, r, &in) {
			return
		}
		in.RequestID = r.Header.Get("X-Request-ID")
		var proof *GoogleProof
		if in.Mode == "link" {
			if !a.MigrationOpen {
				googleError(w, ErrMigrationClosed)
				return
			}
			if in.MigrationTicket != "" {
				ticket, e := a.Attempts.TakeTicket(in.MigrationTicket, "migration", in.DeviceID)
				if e != nil {
					googleError(w, e)
					return
				}
				proof = ticket.Proof
			} else {
				p, e := a.Store.AuthMigrationAccess(bearer(r))
				if e != nil {
					googleError(w, e)
					return
				}
				proof = &p
			}
		}
		out, e := a.Attempts.Begin(googleClientIP(r), in.GoogleAttemptInput, proof)
		if e != nil {
			googleError(w, e)
			return
		}
		writeJSON(w, 200, out)
	})
	mux.HandleFunc("/v2/auth/google/complete", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			AttemptToken string `json:"attempt_token"`
			Code         string `json:"code"`
			Verifier     string `json:"verifier"`
			Nickname     string `json:"nickname"`
		}
		if !googleDecode(w, r, &in) {
			return
		}
		attempt, e := a.Attempts.Claim(in.AttemptToken, in.Verifier)
		if e != nil {
			googleError(w, e)
			return
		}
		identity, e := a.Provider.Exchange(r.Context(), GoogleExchangeInput{Code: in.Code, Verifier: in.Verifier, RedirectURI: attempt.RedirectURI, Nonce: attempt.Nonce})
		if e != nil {
			googleError(w, e)
			return
		}
		if attempt.Mode == "link" {
			if !a.MigrationOpen {
				googleError(w, ErrMigrationClosed)
				return
			}
			p := attempt.Proof
			if p == nil {
				googleError(w, ErrUnauthorized)
				return
			}
			profile, e := a.Store.Profile(p.AccountID)
			if e != nil {
				googleError(w, e)
				return
			}
			ticket, e := a.Attempts.IssueTicket(GoogleTicket{Kind: "link", DeviceID: attempt.DeviceID, AccountID: p.AccountID, Proof: p, Identity: identity})
			if e != nil {
				googleError(w, e)
				return
			}
			writeJSON(w, 200, map[string]any{"status": "link_confirmation", "ticket": ticket, "account_id": p.AccountID, "nickname": profile.Nickname, "friend_id": profile.FriendID, "email": identity.Email})
			return
		}
		id, _, e := a.Store.ResolveGoogle(identity, in.Nickname)
		if e != nil {
			googleError(w, e)
			return
		}
		a.finish(w, id, attempt.DeviceID)
	})
	mux.HandleFunc("/v2/auth/google/link-confirm", func(w http.ResponseWriter, r *http.Request) {
		if !a.MigrationOpen {
			googleError(w, ErrMigrationClosed)
			return
		}
		var in struct {
			Ticket   string `json:"ticket"`
			DeviceID string `json:"device_id"`
		}
		if !googleDecode(w, r, &in) {
			return
		}
		ticket, e := a.Attempts.TakeTicket(in.Ticket, "link", in.DeviceID)
		if e != nil {
			googleError(w, e)
			return
		}
		if ticket.Proof == nil {
			googleError(w, ErrUnauthorized)
			return
		}
		if e = a.Store.LinkGoogle(*ticket.Proof, ticket.Identity); e != nil {
			googleError(w, e)
			return
		}
		a.finish(w, ticket.AccountID, in.DeviceID)
	})
	mux.HandleFunc("/v2/auth/google/takeover", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			Ticket   string `json:"ticket"`
			DeviceID string `json:"device_id"`
		}
		if !googleDecode(w, r, &in) {
			return
		}
		ticket, e := a.Attempts.TakeTicket(in.Ticket, "takeover", in.DeviceID)
		if e != nil {
			googleError(w, e)
			return
		}
		out, e := a.Runtime.IssueGoogleSession(ticket.AccountID, in.DeviceID, true)
		if e != nil {
			googleError(w, e)
			return
		}
		writeJSON(w, 200, out)
	})
	mux.HandleFunc("/v2/auth/google/cancel", func(w http.ResponseWriter, r *http.Request) {
		var in struct {
			AttemptToken string `json:"attempt_token"`
		}
		if !googleDecode(w, r, &in) {
			return
		}
		if e := a.Attempts.Cancel(in.AttemptToken); e != nil {
			googleError(w, e)
			return
		}
		writeJSON(w, 200, map[string]bool{"ok": true})
	})
	mux.HandleFunc("/v2/auth/identity", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" {
			w.WriteHeader(405)
			return
		}
		id, e := a.Store.AuthAccess(bearer(r))
		if e != nil {
			googleError(w, e)
			return
		}
		var email string
		if e = a.Store.db.QueryRow(`SELECT email FROM google_identities WHERE account_id=?`, id).Scan(&email); e != nil {
			googleError(w, e)
			return
		}
		writeJSON(w, 200, map[string]string{"email": email})
	})
}
func (a *GoogleAuthService) finish(w http.ResponseWriter, id, device string) {
	out, e := a.Runtime.IssueGoogleSession(id, device, false)
	if e == ErrTakeoverRequired {
		ticket, te := a.Attempts.IssueTicket(GoogleTicket{Kind: "takeover", AccountID: id, DeviceID: device})
		if te != nil {
			googleError(w, te)
			return
		}
		writeJSON(w, 200, map[string]any{"status": "takeover_required", "ticket": ticket, "account_id": id, "expires_at": time.Now().Add(time.Minute)})
		return
	}
	if e != nil {
		googleError(w, e)
		return
	}
	writeJSON(w, 200, out)
}
