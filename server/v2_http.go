package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
)

type apiError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func writeErr(w http.ResponseWriter, err error) {
	status := http.StatusBadRequest
	code := err.Error()
	switch {
	case errors.Is(err, ErrUnauthorized), errors.Is(err, ErrLoginFailed):
		status = 401
	case errors.Is(err, ErrBlocked):
		status = 403
	case errors.Is(err, ErrAvatarPetNotPresent), errors.Is(err, ErrAvatarTaskRevoked):
		status = 403
	case errors.Is(err, ErrNotFound):
		status = 404
	case errors.Is(err, ErrTakeoverRequired):
		status = 409
	case errors.Is(err, ErrUsernameTaken):
		status = 409
	case errors.Is(err, ErrHostFull):
		status = 409
	case errors.Is(err, ErrRequestExists):
		status = 409
	case errors.Is(err, ErrAvatarBusy), errors.Is(err, ErrAvatarPolicyChanged):
		status = 409
	case errors.Is(err, ErrAvatarRateLimited):
		status = 429
	case errors.Is(err, ErrAvatarTaskExpired):
		status = 410
	}
	writeJSON(w, status, apiError{code, code})
}
func decodeJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	if e := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(v); e != nil {
		writeErr(w, ErrValidation)
		return false
	}
	return true
}
func requestID(w http.ResponseWriter, r *http.Request) bool {
	if strings.TrimSpace(r.Header.Get("X-Request-ID")) == "" {
		writeJSON(w, 400, apiError{"REQUEST_ID_REQUIRED", "REQUEST_ID_REQUIRED"})
		return false
	}
	return true
}
func bearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if !strings.HasPrefix(h, "Bearer ") {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(h, "Bearer "))
}

type storedHTTPResponse struct {
	Fingerprint string              `json:"fingerprint"`
	Status      int                 `json:"status"`
	Header      map[string][]string `json:"header"`
	Body        []byte              `json:"body"`
}

type bufferedResponse struct {
	header http.Header
	status int
	body   bytes.Buffer
}

func (w *bufferedResponse) Header() http.Header { return w.header }
func (w *bufferedResponse) WriteHeader(status int) {
	if w.status == 0 {
		w.status = status
	}
}
func (w *bufferedResponse) Write(p []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	return w.body.Write(p)
}

func replayStored(w http.ResponseWriter, stored storedHTTPResponse) {
	for key, values := range stored.Header {
		for _, value := range values {
			w.Header().Add(key, value)
		}
	}
	w.Header().Set("Idempotency-Replayed", "true")
	w.WriteHeader(stored.Status)
	_, _ = w.Write(stored.Body)
}

// idempotentWrites makes retries safe for invite consumption, token rotation,
// friendship changes, and visit slot allocation. PetLink runs one server
// process, so this lock also closes the check/execute/store race.
func idempotentWrites(s *SocialStore, next http.Handler) http.Handler {
	var mu sync.Mutex
	memory := map[string]storedHTTPResponse{}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		versioned := strings.HasPrefix(r.URL.Path, "/v2/") || strings.HasPrefix(r.URL.Path, "/v3/")
		if (r.Method != http.MethodPost && r.Method != http.MethodPatch) || !versioned || r.URL.Path == "/v2/ws" {
			next.ServeHTTP(w, r)
			return
		}
		request := strings.TrimSpace(r.Header.Get("X-Request-ID"))
		if request == "" {
			next.ServeHTTP(w, r)
			return
		}
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 32<<10))
		if err != nil {
			writeErr(w, ErrValidation)
			return
		}
		r.Body = io.NopCloser(bytes.NewReader(body))
		fpBytes := sha256.Sum256(append([]byte(r.Method+"\n"+r.URL.Path+"\n"), body...))
		fingerprint := fmt.Sprintf("%x", fpBytes[:])
		scope := "public:" + r.URL.Path
		if credential := r.Header.Get("Authorization"); credential != "" {
			h := sha256.Sum256([]byte(credential))
			scope = fmt.Sprintf("auth:%x", h[:])
		}
		memoryOnly := map[string]bool{
			"/v2/auth/register": true, "/v2/auth/login": true, "/v2/auth/takeover": true,
			"/v2/auth/refresh": true, "/v2/auth/recover": true, "/v2/auth/claim": true,
		}[r.URL.Path]
		memoryKey := scope + "\x00" + request

		mu.Lock()
		defer mu.Unlock()
		var stored storedHTTPResponse
		found := false
		if memoryOnly {
			stored, found = memory[memoryKey]
		} else {
			var raw string
			err = s.db.QueryRow(`SELECT response_json FROM idempotency WHERE account_id=? AND request_id=?`, scope, request).Scan(&raw)
			if err == nil {
				if json.Unmarshal([]byte(raw), &stored) != nil {
					writeJSON(w, 500, apiError{"IDEMPOTENCY_CORRUPT", "IDEMPOTENCY_CORRUPT"})
					return
				}
				found = true
			}
		}
		if found {
			if stored.Fingerprint != fingerprint {
				writeJSON(w, 409, apiError{"IDEMPOTENCY_CONFLICT", "IDEMPOTENCY_CONFLICT"})
				return
			}
			replayStored(w, stored)
			return
		}

		buffer := &bufferedResponse{header: make(http.Header)}
		next.ServeHTTP(buffer, r)
		if buffer.status == 0 {
			buffer.status = http.StatusOK
		}
		stored = storedHTTPResponse{Fingerprint: fingerprint, Status: buffer.status, Header: buffer.header, Body: buffer.body.Bytes()}
		if memoryOnly {
			if len(memory) >= 2048 {
				memory = map[string]storedHTTPResponse{}
			}
			memory[memoryKey] = stored
		} else {
			encoded, _ := json.Marshal(stored)
			_, _ = s.db.Exec(`INSERT OR REPLACE INTO idempotency(account_id,request_id,response_json,created_at) VALUES(?,?,?,?)`, scope, request, string(encoded), time.Now().UnixMilli())
			_, _ = s.db.Exec(`DELETE FROM idempotency WHERE created_at<?`, time.Now().Add(-24*time.Hour).UnixMilli())
		}
		replayStored(w, stored)
	})
}

func SocialHandler(s *SocialStore) http.Handler {
	return SocialHandlerWithRuntime(s, NewSocialRuntime(s))
}

type V2Auth struct {
	AccessToken               string `json:"access_token"`
	DeviceID                  string `json:"device_id"`
	Protocol                  int    `json:"protocol"`
	SupportsCredentialRefresh bool   `json:"supports_credential_refresh,omitempty"`
}
type V2Command struct {
	RequestID   string       `json:"request_id"`
	Action      string       `json:"action"`
	PeerID      string       `json:"peer_id,omitempty"`
	PetID       string       `json:"pet_id,omitempty"`
	VisitID     string       `json:"visit_id,omitempty"`
	Revision    int64        `json:"revision,omitempty"`
	Style       int          `json:"style,omitempty"`
	Enabled     bool         `json:"enabled,omitempty"`
	Agent       *AgentStatus `json:"agent,omitempty"`
	AccessToken string       `json:"access_token,omitempty"`
}

func SocialHandlerWithRuntime(s *SocialStore, rt *SocialRuntime) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if e := s.db.Ping(); e != nil {
			writeJSON(w, 503, apiError{"STORAGE_UNAVAILABLE", "STORAGE_UNAVAILABLE"})
			return
		}
		writeJSON(w, 200, map[string]any{"status": "ok", "version": version})
	})
	mux.HandleFunc("/pair", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusUpgradeRequired, apiError{"CLIENT_UPGRADE_REQUIRED", "CLIENT_UPGRADE_REQUIRED"})
	})
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusUpgradeRequired, apiError{"CLIENT_UPGRADE_REQUIRED", "CLIENT_UPGRADE_REQUIRED"})
	})
	mux.HandleFunc("/v2/auth/register", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			w.WriteHeader(405)
			return
		}
		if !requestID(w, r) {
			return
		}
		var in struct {
			RequestID string `json:"request_id"`
			Invite    string `json:"invite"`
			Username  string `json:"username"`
			Password  string `json:"password"`
			Nickname  string `json:"nickname"`
			DeviceID  string `json:"device_id"`
		}
		if !decodeJSON(w, r, &in) {
			return
		}
		out, e := s.Register(RegisterInput{in.Invite, in.Username, in.Password, in.Nickname, in.DeviceID})
		if e != nil {
			writeErr(w, e)
			return
		}
		writeJSON(w, 201, out)
	})
	mux.HandleFunc("/v2/auth/login", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			w.WriteHeader(405)
			return
		}
		if !requestID(w, r) {
			return
		}
		var in struct {
			Username string `json:"username"`
			Password string `json:"password"`
			DeviceID string `json:"device_id"`
		}
		if !decodeJSON(w, r, &in) {
			return
		}
		out, e := s.Login(LoginInput{in.Username, in.Password, in.DeviceID})
		if e != nil {
			writeErr(w, e)
			return
		}
		writeJSON(w, 200, out)
	})
	mux.HandleFunc("/v2/auth/takeover", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			w.WriteHeader(405)
			return
		}
		if !requestID(w, r) {
			return
		}
		var in struct {
			Username string `json:"username"`
			Password string `json:"password"`
			DeviceID string `json:"device_id"`
		}
		if !decodeJSON(w, r, &in) {
			return
		}
		out, e := s.Takeover(TakeoverInput{in.Username, in.Password, in.DeviceID})
		if e != nil {
			writeErr(w, e)
			return
		}
		writeJSON(w, 200, out)
	})
	mux.HandleFunc("/v2/auth/refresh", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			w.WriteHeader(405)
			return
		}
		if !requestID(w, r) {
			return
		}
		var in struct {
			RefreshToken string `json:"refresh_token"`
		}
		if !decodeJSON(w, r, &in) {
			return
		}
		out, e := s.Refresh(in.RefreshToken)
		if e != nil {
			writeErr(w, e)
			return
		}
		writeJSON(w, 200, out)
	})
	mux.HandleFunc("/v2/auth/recover", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			w.WriteHeader(405)
			return
		}
		if !requestID(w, r) {
			return
		}
		var in struct {
			Username     string `json:"username"`
			RecoveryCode string `json:"recovery_code"`
			NewPassword  string `json:"new_password"`
			DeviceID     string `json:"device_id"`
		}
		if !decodeJSON(w, r, &in) {
			return
		}
		out, e := s.Recover(RecoverInput{in.Username, in.RecoveryCode, in.NewPassword, in.DeviceID})
		if e != nil {
			writeErr(w, e)
			return
		}
		writeJSON(w, 200, out)
	})
	mux.HandleFunc("/v2/auth/claim", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			w.WriteHeader(405)
			return
		}
		if !requestID(w, r) {
			return
		}
		var in struct {
			LegacyToken string `json:"legacy_token"`
			Username    string `json:"username"`
			Password    string `json:"password"`
			Nickname    string `json:"nickname"`
			DeviceID    string `json:"device_id"`
		}
		if !decodeJSON(w, r, &in) {
			return
		}
		out, e := s.ClaimLegacy(ClaimInput{in.LegacyToken, in.Username, in.Password, in.Nickname, in.DeviceID})
		if e != nil {
			writeErr(w, e)
			return
		}
		writeJSON(w, 200, out)
	})
	auth := func(next func(http.ResponseWriter, *http.Request, string)) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			id, e := s.AuthAccess(bearer(r))
			if e != nil {
				writeErr(w, e)
				return
			}
			next(w, r, id)
		}
	}
	mux.HandleFunc("/v2/me", auth(func(w http.ResponseWriter, r *http.Request, id string) {
		if r.Method == "PATCH" {
			if !requestID(w, r) {
				return
			}
			var in struct {
				Nickname string `json:"nickname"`
			}
			if !decodeJSON(w, r, &in) {
				return
			}
			if e := s.SetNickname(id, in.Nickname); e != nil {
				writeErr(w, e)
				return
			}
		} else if r.Method != "GET" {
			w.WriteHeader(405)
			return
		}
		p, e := s.Profile(id)
		if e != nil {
			writeErr(w, ErrNotFound)
			return
		}
		writeJSON(w, 200, p)
	}))
	mux.HandleFunc("/v2/auth/logout", auth(func(w http.ResponseWriter, r *http.Request, id string) {
		if r.Method != "POST" {
			w.WriteHeader(405)
			return
		}
		if !requestID(w, r) {
			return
		}
		if e := s.Logout(bearer(r)); e != nil {
			writeErr(w, e)
			return
		}
		writeJSON(w, 200, map[string]bool{"ok": true})
	}))
	mux.HandleFunc("/v2/contacts", auth(func(w http.ResponseWriter, r *http.Request, id string) {
		if r.Method != "GET" {
			w.WriteHeader(405)
			return
		}
		v, e := s.Contacts(id)
		if e != nil {
			writeErr(w, e)
			return
		}
		writeJSON(w, 200, map[string]any{"contacts": v})
	}))
	mux.HandleFunc("/v2/requests", auth(func(w http.ResponseWriter, r *http.Request, id string) {
		if r.Method != "GET" {
			w.WriteHeader(405)
			return
		}
		friends, e := s.PendingFriendRequests(id)
		if e != nil {
			writeErr(w, e)
			return
		}
		visits, e := s.PendingVisitRequests(id)
		if e != nil {
			writeErr(w, e)
			return
		}
		writeJSON(w, 200, map[string]any{"friend_requests": friends, "visit_requests": visits})
	}))
	mux.HandleFunc("/v2/friends/request", auth(func(w http.ResponseWriter, r *http.Request, id string) {
		if r.Method != "POST" {
			w.WriteHeader(405)
			return
		}
		if !requestID(w, r) {
			return
		}
		var in struct {
			FriendID string `json:"friend_id"`
		}
		if !decodeJSON(w, r, &in) {
			return
		}
		v, e := s.RequestFriend(id, in.FriendID)
		if e != nil {
			writeErr(w, e)
			return
		}
		writeJSON(w, 201, v)
	}))
	mux.HandleFunc("/v2/friends/respond", auth(func(w http.ResponseWriter, r *http.Request, id string) {
		if r.Method != "POST" {
			w.WriteHeader(405)
			return
		}
		if !requestID(w, r) {
			return
		}
		var in struct {
			RequestID string `json:"request_id"`
			Accept    bool   `json:"accept"`
		}
		if !decodeJSON(w, r, &in) {
			return
		}
		if e := s.RespondFriend(id, in.RequestID, in.Accept); e != nil {
			writeErr(w, e)
			return
		}
		writeJSON(w, 200, map[string]bool{"ok": true})
	}))
	mux.HandleFunc("/v2/friends/block", auth(func(w http.ResponseWriter, r *http.Request, id string) {
		if r.Method != "POST" {
			w.WriteHeader(405)
			return
		}
		if !requestID(w, r) {
			return
		}
		var in struct {
			AccountID string `json:"account_id"`
		}
		if !decodeJSON(w, r, &in) {
			return
		}
		if e := s.Block(id, in.AccountID); e != nil {
			writeErr(w, e)
			return
		}
		writeJSON(w, 200, map[string]bool{"ok": true})
	}))
	mux.HandleFunc("/v2/friends/remove", auth(func(w http.ResponseWriter, r *http.Request, id string) {
		if r.Method != "POST" {
			w.WriteHeader(405)
			return
		}
		if !requestID(w, r) {
			return
		}
		var in struct {
			AccountID string `json:"account_id"`
		}
		if !decodeJSON(w, r, &in) {
			return
		}
		if e := s.RemoveFriend(id, in.AccountID); e != nil {
			writeErr(w, e)
			return
		}
		writeJSON(w, 200, map[string]bool{"ok": true})
	}))
	mux.HandleFunc("/v2/contacts/", auth(func(w http.ResponseWriter, r *http.Request, id string) {
		if r.Method != "PATCH" {
			w.WriteHeader(405)
			return
		}
		if !requestID(w, r) {
			return
		}
		peer := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/v2/contacts/"), "/policy")
		if peer == "" {
			writeErr(w, ErrNotFound)
			return
		}
		var p ContactPolicy
		if !decodeJSON(w, r, &p) {
			return
		}
		if e := s.SetContactPolicy(id, peer, p); e != nil {
			writeErr(w, e)
			return
		}
		writeJSON(w, 200, map[string]bool{"ok": true})
	}))
	mux.HandleFunc("/v2/visits/request", auth(func(w http.ResponseWriter, r *http.Request, id string) {
		if r.Method != "POST" {
			w.WriteHeader(405)
			return
		}
		if !requestID(w, r) {
			return
		}
		var in struct {
			HostID string `json:"host_id"`
		}
		if !decodeJSON(w, r, &in) {
			return
		}
		v, e := rt.RequestVisit(id, in.HostID)
		if e != nil {
			writeErr(w, e)
			return
		}
		writeJSON(w, 201, v)
	}))
	mux.HandleFunc("/v2/visits/respond", auth(func(w http.ResponseWriter, r *http.Request, id string) {
		if r.Method != "POST" {
			w.WriteHeader(405)
			return
		}
		if !requestID(w, r) {
			return
		}
		var in struct {
			RequestID string `json:"request_id"`
			Accept    bool   `json:"accept"`
		}
		if !decodeJSON(w, r, &in) {
			return
		}
		if e := s.RespondVisit(id, in.RequestID, in.Accept); e != nil {
			writeErr(w, e)
			return
		}
		writeJSON(w, 200, map[string]bool{"ok": true})
	}))
	mux.HandleFunc("/v2/visits/cancel", auth(func(w http.ResponseWriter, r *http.Request, id string) {
		if r.Method != "POST" {
			w.WriteHeader(405)
			return
		}
		if !requestID(w, r) {
			return
		}
		var in struct {
			RequestID string `json:"request_id"`
		}
		if !decodeJSON(w, r, &in) {
			return
		}
		if e := s.CancelVisit(id, in.RequestID); e != nil {
			writeErr(w, e)
			return
		}
		writeJSON(w, 200, map[string]bool{"ok": true})
	}))
	mux.HandleFunc("/v2/ws", func(w http.ResponseWriter, r *http.Request) {
		c, e := websocket.Accept(w, r, nil)
		if e != nil {
			return
		}
		defer c.CloseNow()
		c.SetReadLimit(8 << 10)
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		var auth V2Auth
		e = wsjson.Read(ctx, c, &auth)
		cancel()
		if e != nil || auth.Protocol != 2 {
			_ = c.Close(websocket.StatusPolicyViolation, "CLIENT_UPGRADE_REQUIRED")
			return
		}
		account, e := s.AuthAccess(auth.AccessToken)
		if e != nil {
			_ = c.Close(websocket.StatusPolicyViolation, "UNAUTHORIZED")
			return
		}
		sid := newID("ws_")
		if e = rt.Connect(account, auth.DeviceID, sid); e != nil {
			_ = c.Close(websocket.StatusPolicyViolation, e.Error())
			return
		}
		defer rt.Disconnect(account, sid)
		seen := map[string]V2Snapshot{}
		var refreshDeadline time.Time
		for {
			readTimeout := 12 * time.Second
			if !refreshDeadline.IsZero() {
				if remaining := time.Until(refreshDeadline); remaining <= 0 {
					return
				} else if remaining < readTimeout {
					readTimeout = remaining
				}
			}
			ctx, cancel = context.WithTimeout(r.Context(), readTimeout)
			var cmd V2Command
			e = wsjson.Read(ctx, c, &cmd)
			cancel()
			if e != nil {
				return
			}
			if cmd.RequestID == "" {
				_ = c.Close(websocket.StatusPolicyViolation, "REQUEST_ID_REQUIRED")
				return
			}
			// A renewed token may only reauthorize this account and device. The
			// existing transport stays bound to sid, so renewal is not a departure.
			if cmd.Action == "reauth" {
				newAccount, authErr := s.AuthAccess(cmd.AccessToken)
				profile, profileErr := s.Profile(account)
				if !auth.SupportsCredentialRefresh || authErr != nil || newAccount != account || profileErr != nil || profile.ActiveDevice != auth.DeviceID {
					_ = c.Close(websocket.StatusPolicyViolation, "UNAUTHORIZED")
					return
				}
				auth.AccessToken = cmd.AccessToken
				refreshDeadline = time.Time{}
			}
			if s.googleOnly.Load() {
				profile, authErr := s.Profile(account)
				if authErr != nil || profile.ActiveDevice != auth.DeviceID {
					_ = c.Close(websocket.StatusPolicyViolation, "DEVICE_REPLACED")
					return
				}
				if _, authErr = s.AuthAccess(auth.AccessToken); authErr != nil {
					if !auth.SupportsCredentialRefresh {
						_ = c.Close(websocket.StatusPolicyViolation, "UNAUTHORIZED")
						return
					}
					if refreshDeadline.IsZero() {
						refreshDeadline = time.Now().Add(8 * time.Second)
					}
					// No snapshot, cached reply or mutation is allowed while the
					// credential is invalid. Only this bounded renewal control is sent.
					ctx, cancel = context.WithTimeout(r.Context(), time.Until(refreshDeadline))
					e = wsjson.Write(ctx, c, map[string]string{"type": "auth_refresh_required", "request_id": cmd.RequestID})
					cancel()
					if e != nil {
						return
					}
					continue
				}
			}
			if cached, ok := seen[cmd.RequestID]; ok {
				ctx, cancel = context.WithTimeout(r.Context(), 4*time.Second)
				e = wsjson.Write(ctx, c, cached)
				cancel()
				if e != nil {
					return
				}
				continue
			}
			switch cmd.Action {
			case "sync", "reauth":
			case "ack":
				e = rt.AckHide(account, auth.DeviceID, sid, cmd.PetID, cmd.Revision)
			case "style":
				e = rt.Style(account, cmd.Style)
			case "wave":
				e = rt.Wave(account)
			case "visit_request":
				_, e = rt.RequestVisit(account, cmd.PeerID)
			case "visit_respond":
				e = s.RespondVisit(account, cmd.VisitID, cmd.Enabled)
			case "visit_cancel":
				e = s.CancelVisit(account, cmd.VisitID)
			case "recall":
				e = rt.Recall(account)
			case "send_home":
				e = rt.SendHome(account, cmd.PetID)
			case "send_all_home":
				e = rt.SendAllHome(account)
			case "pause_accepting":
				e = rt.SetAccepting(account, !cmd.Enabled)
			case "agent_status":
				if cmd.Agent == nil {
					e = ErrValidation
				} else {
					e = s.UpdateAgentStatus(account, *cmd.Agent)
				}
			default:
				e = ErrValidation
			}
			snap, se := rt.Snapshot(account, auth.DeviceID, sid, cmd.RequestID)
			if se != nil && e == nil {
				e = se
			}
			if e != nil {
				snap.Error = e.Error()
			}
			if len(seen) >= 512 {
				seen = map[string]V2Snapshot{}
			}
			seen[cmd.RequestID] = snap
			ctx, cancel = context.WithTimeout(r.Context(), 4*time.Second)
			e = wsjson.Write(ctx, c, snap)
			cancel()
			if e != nil {
				return
			}
		}
	})
	registerAvatarHandlers(mux, s, rt, auth)
	return idempotentWrites(s, mux)
}
