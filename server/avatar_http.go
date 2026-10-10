package main

import (
	"net/http"
	"strings"
)

type avatarAuthWrapper func(func(http.ResponseWriter, *http.Request, string)) http.HandlerFunc

func registerAvatarHandlers(mux *http.ServeMux, s *SocialStore, rt *SocialRuntime, auth avatarAuthWrapper) {
	mux.HandleFunc("/v3/avatar/capabilities", auth(func(w http.ResponseWriter, r *http.Request, account string) {
		if r.Method != http.MethodGet {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		_, err := s.ActiveDeviceKey(account)
		writeJSON(w, http.StatusOK, map[string]any{"protocol": 3, "key_registered": err == nil, "max_question_bytes": 8192, "max_answer_bytes": 32768})
	}))

	mux.HandleFunc("/v3/devices/keys", auth(func(w http.ResponseWriter, r *http.Request, account string) {
		if r.Method != http.MethodPost || !requestID(w, r) {
			if r.Method != http.MethodPost {
				w.WriteHeader(http.StatusMethodNotAllowed)
			}
			return
		}
		var in struct {
			Authorize          bool   `json:"authorize"`
			DeviceID           string `json:"device_id"`
			AgreementPublicKey string `json:"agreement_public_key"`
			SigningPublicKey   string `json:"signing_public_key"`
		}
		if !decodeJSON(w, r, &in) {
			return
		}
		if !in.Authorize {
			writeJSON(w, http.StatusBadRequest, map[string]string{"code": "AVATAR_AUTHORIZATION_REQUIRED", "message": "请先在数字分身页面授权"})
			return
		}
		key, err := s.RegisterDeviceKeys(account, in.DeviceID, in.AgreementPublicKey, in.SigningPublicKey)
		if err != nil {
			writeErr(w, err)
			return
		}
		writeJSON(w, http.StatusCreated, key)
	}))

	mux.HandleFunc("/v3/avatar/contacts/", auth(func(w http.ResponseWriter, r *http.Request, account string) {
		if r.Method != http.MethodGet || !strings.HasSuffix(r.URL.Path, "/capability") {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		owner := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/v3/avatar/contacts/"), "/capability")
		capability, err := s.AvatarContactCapability(account, owner)
		if err != nil {
			writeErr(w, err)
			return
		}
		writeJSON(w, http.StatusOK, capability)
	}))

	mux.HandleFunc("/v3/contacts/", auth(func(w http.ResponseWriter, r *http.Request, account string) {
		if r.Method != http.MethodPatch || !strings.HasSuffix(r.URL.Path, "/avatar-policy") || !requestID(w, r) {
			if r.Method != http.MethodPatch {
				w.WriteHeader(http.StatusMethodNotAllowed)
			}
			return
		}
		peer := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/v3/contacts/"), "/avatar-policy")
		if peer == "" {
			writeErr(w, ErrNotFound)
			return
		}
		var in AvatarPolicy
		if !decodeJSON(w, r, &in) {
			return
		}
		policy, err := s.SetAvatarPolicy(account, peer, in)
		if err != nil {
			writeErr(w, err)
			return
		}
		writeJSON(w, http.StatusOK, policy)
	}))

	mux.HandleFunc("/v3/avatar/tasks", auth(func(w http.ResponseWriter, r *http.Request, account string) {
		if r.Method != http.MethodPost || !requestID(w, r) {
			if r.Method != http.MethodPost {
				w.WriteHeader(http.StatusMethodNotAllowed)
			}
			return
		}
		var in struct {
			OwnerID  string         `json:"owner_id"`
			Envelope AvatarEnvelope `json:"envelope"`
		}
		if !decodeJSON(w, r, &in) {
			return
		}
		task, err := rt.SubmitAvatar(account, in.Envelope.SenderDeviceID, in.OwnerID, in.Envelope)
		if err != nil {
			writeErr(w, err)
			return
		}
		writeJSON(w, http.StatusCreated, task)
	}))

	mux.HandleFunc("/v3/avatar/tasks/", auth(func(w http.ResponseWriter, r *http.Request, account string) {
		path := strings.TrimPrefix(r.URL.Path, "/v3/avatar/tasks/")
		parts := strings.Split(strings.Trim(path, "/"), "/")
		if len(parts) < 1 || parts[0] == "" {
			writeErr(w, ErrNotFound)
			return
		}
		taskID := parts[0]
		if r.Method == http.MethodGet && len(parts) == 1 {
			task, err := s.AvatarTask(taskID)
			if err != nil || account != task.OwnerID && account != task.RequesterID {
				writeErr(w, ErrNotFound)
				return
			}
			writeJSON(w, http.StatusOK, task)
			return
		}
		if r.Method != http.MethodPost || len(parts) != 2 || !requestID(w, r) {
			if r.Method != http.MethodPost {
				w.WriteHeader(http.StatusMethodNotAllowed)
			}
			return
		}
		switch parts[1] {
		case "respond":
			var in struct {
				Accept   bool `json:"accept"`
				Remember bool `json:"remember"`
			}
			if !decodeJSON(w, r, &in) {
				return
			}
			if err := rt.RespondAvatarWithConsent(account, taskID, in.Accept, in.Remember); err != nil {
				writeErr(w, err)
				return
			}
			writeJSON(w, http.StatusOK, map[string]bool{"ok": true, "auto_ask_granted": in.Remember})
			return
		case "cancel":
			if err := rt.CancelAvatar(account, taskID); err != nil {
				writeErr(w, err)
				return
			}
		case "start":
			if err := rt.StartAvatar(account, taskID); err != nil {
				writeErr(w, err)
				return
			}
		case "complete":
			var in struct {
				Envelope AvatarEnvelope `json:"envelope"`
			}
			if !decodeJSON(w, r, &in) {
				return
			}
			if err := rt.CompleteAvatar(account, taskID, in.Envelope); err != nil {
				writeErr(w, err)
				return
			}
		default:
			writeErr(w, ErrNotFound)
			return
		}
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
	}))
}
