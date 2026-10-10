package main

import (
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

const googleTestVerifier = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"

func googleTestAttempt() GoogleAttemptInput {
	h := sha256.Sum256([]byte(googleTestVerifier))
	return GoogleAttemptInput{DeviceID: "device-one", Challenge: base64.RawURLEncoding.EncodeToString(h[:]), RedirectURI: "http://127.0.0.1:34567/callback/abcdefghijklmnopqrstuv", Mode: "login", RequestID: "request-one"}
}
func TestGoogleAttemptsLimits(t *testing.T) {
	now := time.Now()
	a := newGoogleAttempts("test-client", func() time.Time { return now })
	for i := 0; i < 10; i++ {
		if _, e := a.Begin("192.0.2.1", googleTestAttempt(), nil); e != nil {
			t.Fatal(e)
		}
	}
	if _, e := a.Begin("192.0.2.1", googleTestAttempt(), nil); e == nil {
		t.Fatal("eleventh IP request accepted")
	}
	now = now.Add(time.Minute)
	if _, e := a.Begin("192.0.2.1", googleTestAttempt(), nil); e != nil {
		t.Fatal(e)
	}
	a = newGoogleAttempts("test-client", func() time.Time { return now })
	for i := 0; i < 200; i++ {
		if _, e := a.Begin(fmt.Sprintf("192.0.2.%d", i), googleTestAttempt(), nil); e != nil {
			t.Fatal(i, e)
		}
	}
	for i := 0; i < 10000; i++ {
		if _, e := a.Begin(fmt.Sprintf("198.51.%d.%d", i/256, i%256), googleTestAttempt(), nil); e == nil {
			t.Fatal("capacity exceeded")
		}
	}
	if len(a.attempts) > 200 || len(a.rates) > 200 {
		t.Fatal("unbounded state")
	}
	now = now.Add(5 * time.Minute)
	if _, e := a.Begin("new-ip", googleTestAttempt(), nil); e != nil {
		t.Fatal("expired capacity retained", e)
	}
}
func TestGoogleAttemptSingleUse(t *testing.T) {
	now := time.Now()
	a := newGoogleAttempts("test-client", func() time.Time { return now })
	out, e := a.Begin("192.0.2.1", googleTestAttempt(), nil)
	if e != nil {
		t.Fatal(e)
	}
	b, e := base64.RawURLEncoding.DecodeString(out.AttemptToken)
	if e != nil || len(b) < 32 {
		t.Fatal("weak bearer")
	}
	if out.Nonce == "" || !out.ExpiresAt.Equal(now.Add(5*time.Minute)) {
		t.Fatal("missing nonce/expiry")
	}
	if _, e = a.Claim(out.AttemptToken, strings.Repeat("x", 43)); e == nil {
		t.Fatal("bad verifier accepted")
	}
	var successes atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, e := a.Claim(out.AttemptToken, googleTestVerifier); e == nil {
				successes.Add(1)
			}
		}()
	}
	wg.Wait()
	if successes.Load() != 1 {
		t.Fatalf("claimed %d times", successes.Load())
	}
	out, e = a.Begin("192.0.2.1", googleTestAttempt(), nil)
	if e != nil {
		t.Fatal(e)
	}
	if e = a.Cancel(out.AttemptToken); e != nil {
		t.Fatal(e)
	}
	if _, e = a.Claim(out.AttemptToken, googleTestVerifier); e == nil {
		t.Fatal("cancelled accepted")
	}
	out, _ = a.Begin("192.0.2.1", googleTestAttempt(), nil)
	now = now.Add(5 * time.Minute)
	if _, e = a.Claim(out.AttemptToken, googleTestVerifier); e == nil {
		t.Fatal("expired accepted")
	}
	if _, e = newGoogleAttempts("test-client", time.Now).Claim(out.AttemptToken, googleTestVerifier); e == nil {
		t.Fatal("restart retained state")
	}
}
func TestGoogleRedirectValidation(t *testing.T) {
	a := newGoogleAttempts("test-client", time.Now)
	for _, uri := range []string{"http://localhost:1234/callback/abcdefghijklmnopqrstuv", "https://attacker.invalid/callback/abcdefghijklmnopqrstuv", "http://127.0.0.1:1234@attacker.invalid/callback/abcdefghijklmnopqrstuv", "http://127.0.0.1:1234/callback/abcdefghijklmnopqrstuv#x", "http://127.0.0.1:0/callback/abcdefghijklmnopqrstuv", "http://127.0.0.1:1234/", "http://0.0.0.0:1234/callback/abcdefghijklmnopqrstuv", "http://127.0.0.1:1234/callback/abcdefghijklmnopqrstuv?x=1"} {
		in := googleTestAttempt()
		in.RedirectURI = uri
		if _, e := a.Begin("ip", in, nil); e == nil {
			t.Errorf("accepted %s", uri)
		}
	}
	in := googleTestAttempt()
	in.Mode = "link"
	if _, e := a.Begin("ip", in, nil); e == nil {
		t.Fatal("unauthenticated link")
	}
	if _, e := a.Begin("ip", in, &GoogleProof{AccountID: "account"}); e != nil {
		t.Fatal(e)
	}
}
func TestGoogleTicketsBoundAndExpire(t *testing.T) {
	now := time.Now()
	a := newGoogleAttempts("client", func() time.Time { return now })
	ticket := GoogleTicket{Kind: "takeover", DeviceID: "device", AccountID: "account"}
	raw, e := a.IssueTicket(ticket)
	if e != nil {
		t.Fatal(e)
	}
	if _, e = a.TakeTicket(raw, "link", "device"); e == nil {
		t.Fatal("wrong kind accepted")
	}
	if _, e = a.TakeTicket(raw, "takeover", "other"); e == nil {
		t.Fatal("wrong device accepted")
	}
	now = now.Add(60 * time.Second)
	if _, e = a.TakeTicket(raw, "takeover", "device"); e == nil {
		t.Fatal("expired accepted")
	}
	raw, _ = a.IssueTicket(ticket)
	if _, e = a.TakeTicket(raw, "takeover", "device"); e != nil {
		t.Fatal(e)
	}
	if _, e = a.TakeTicket(raw, "takeover", "device"); e == nil {
		t.Fatal("replay accepted")
	}
}
