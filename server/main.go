package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"log"
	"net/http"
	"net/netip"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

const version = "0.4.0"

func Handler(h *Hub) http.Handler {
	mux := http.NewServeMux()
	// Pairing is intentionally invite-only and globally throttled for this small experiment.
	var pairMu sync.Mutex
	var attempts []time.Time
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		if h.Health() != nil {
			http.Error(w, "storage unavailable; operator recovery required", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{"status": "ok", "version": version})
	})
	mux.HandleFunc("/pair", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "POST" {
			http.Error(w, "POST required", 405)
			return
		}
		pairMu.Lock()
		now := time.Now()
		keep := attempts[:0]
		for _, t := range attempts {
			if now.Sub(t) < time.Minute {
				keep = append(keep, t)
			}
		}
		attempts = keep
		if len(attempts) >= 10 {
			pairMu.Unlock()
			http.Error(w, "稍后再试", 429)
			return
		}
		attempts = append(attempts, now)
		pairMu.Unlock()
		var body struct {
			Code string `json:"code"`
		}
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&body) != nil {
			http.Error(w, "invalid request", 400)
			return
		}
		id, token, e := h.Pair(strings.TrimSpace(body.Code))
		if e != nil {
			http.Error(w, e.Error(), 403)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		json.NewEncoder(w).Encode(map[string]string{"id": id, "token": token})
	})
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		c, e := websocket.Accept(w, r, nil)
		if e != nil {
			return
		}
		defer c.CloseNow()
		c.SetReadLimit(4096)
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		var auth struct {
			Token string `json:"token"`
		}
		e = wsjson.Read(ctx, c, &auth)
		cancel()
		if e != nil {
			return
		}
		id := h.Auth(auth.Token)
		if id == "" {
			c.Close(websocket.StatusPolicyViolation, "invalid credential")
			return
		}
		sid := randomToken()
		h.Connect(id, sid)
		defer h.Disconnect(id, sid)
		window := time.Now()
		count := 0
		for {
			ctx, cancel = context.WithTimeout(r.Context(), 12*time.Second)
			var cmd Command
			e = wsjson.Read(ctx, c, &cmd)
			cancel()
			if e != nil {
				return
			}
			if time.Since(window) > time.Second {
				window = time.Now()
				count = 0
			}
			count++
			if count > 20 {
				c.Close(websocket.StatusPolicyViolation, "rate limited")
				return
			}
			if len(cmd.ID) > 80 || cmd.ID == "" {
				c.Close(websocket.StatusPolicyViolation, "request id required")
				return
			}
			e = h.Act(id, sid, cmd)
			s := h.Snapshot(id, sid)
			s.ID = cmd.ID
			if e != nil {
				s.Error = e.Error()
			}
			ctx, cancel = context.WithTimeout(r.Context(), 4*time.Second)
			e = wsjson.Write(ctx, c, s)
			cancel()
			if e != nil {
				return
			}
		}
	})
	return mux
}

func main() {
	addr := flag.String("listen", "127.0.0.1:18746", "listen address")
	db := flag.String("db", "state.db", "SQLite path")
	initDir := flag.String("init-dir", "", "create registration invitations into private directory, then exit")
	inviteCount := flag.Int("invite-count", 20, "number of registration invitations")
	authMode := flag.String("auth-mode", "google", "google, or explicit local-test legacy authentication")
	googleConfig := flag.String("google-config", "", "private Google OAuth JSON configuration file")
	migrationOpen := flag.Bool("migration-open", false, "allow legacy account migration")
	var trustedProxies []netip.Prefix
	flag.Func("trusted-proxy", "trusted reverse proxy CIDR; repeat for multiple ranges", func(value string) error {
		prefix, err := netip.ParsePrefix(value)
		if err != nil {
			return fmt.Errorf("invalid trusted proxy CIDR")
		}
		trustedProxies = append(trustedProxies, prefix)
		return nil
	})
	flag.Parse()
	var oauthConfig GoogleConfig
	if *authMode == "google" {
		var err error
		oauthConfig, err = loadGoogleConfig(*googleConfig)
		if err != nil {
			log.Fatal("Google OAuth configuration is missing or invalid")
		}
		if *initDir != "" {
			log.Fatal("invitation registration is disabled in Google mode")
		}
	} else if *authMode != "legacy-test" || !(strings.HasPrefix(*addr, "127.0.0.1:") || strings.HasPrefix(*addr, "[::1]:")) {
		log.Fatal("legacy-test mode is restricted to explicit loopback test listeners")
	}
	syscall.Umask(0077)
	social, e := OpenSocialStore(*db)
	if e != nil {
		log.Fatal(e)
	}
	defer social.Close()
	if e = social.MigrateLegacy(); e != nil {
		log.Fatal(e)
	}
	if *initDir != "" {
		if e = os.MkdirAll(*initDir, 0700); e != nil {
			log.Fatal(e)
		}
		if *inviteCount < 1 || *inviteCount > 100 {
			log.Fatal("invite-count must be 1..100")
		}
		for i := 1; i <= *inviteCount; i++ {
			code := randomToken()
			if e = social.CreateInvite(code, time.Now().Add(7*24*time.Hour)); e != nil {
				log.Fatal(e)
			}
			p := filepath.Join(*initDir, fmt.Sprintf("invite-%02d.txt", i))
			if e = os.WriteFile(p, []byte(code+"\n"), 0600); e != nil {
				log.Fatal(e)
			}
		}
		log.Printf("%d registration invitations created; values are not logged.", *inviteCount)
		return
	}
	var handler http.Handler
	if *authMode == "google" {
		provider, err := NewGoogleProvider(oauthConfig)
		if err != nil {
			log.Fatal("invalid Google configuration")
		}
		handler = GoogleHandler(&GoogleAuthService{Store: social, Runtime: NewSocialRuntime(social), Attempts: newGoogleAttempts(oauthConfig.ClientID, time.Now), Provider: provider, MigrationOpen: *migrationOpen})
	} else {
		handler = SocialHandler(social)
	}
	srv := &http.Server{Addr: *addr, Handler: withTrustedProxy(handler, trustedProxies), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 8192}
	done := make(chan os.Signal, 1)
	signal.Notify(done, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-done
		ctx, c := context.WithTimeout(context.Background(), 5*time.Second)
		defer c()
		srv.Shutdown(ctx)
	}()
	log.Printf("PetLink %s starting", version)
	if e = srv.ListenAndServe(); e != nil && e != http.ErrServerClosed {
		log.Fatal(e)
	}
}
