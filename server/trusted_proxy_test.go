package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"
)

func TestTrustedProxyGoogleQuotaIsolation(t *testing.T) {
	_, _, original := googleTestService(t)
	handler := withTrustedProxy(original, []netip.Prefix{netip.MustParsePrefix("10.0.2.0/24")})
	begin := func(peer, forwarded string) int {
		raw, err := json.Marshal(googleTestAttempt())
		if err != nil {
			t.Fatal(err)
		}
		request := httptest.NewRequest(http.MethodPost, "http://petlink.test/v2/auth/google/begin", bytes.NewReader(raw))
		request.RemoteAddr = peer
		request.Header.Set("X-Request-ID", newID("req_"))
		request.Header.Set("X-Forwarded-For", forwarded)
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, request)
		return response.Code
	}
	for i := 0; i < 10; i++ {
		if status := begin("10.0.2.100:1234", "198.51.100.10"); status != 200 {
			t.Fatal("first client", i, status)
		}
	}
	if status := begin("10.0.2.100:1234", "198.51.100.10"); status != 429 {
		t.Fatal("first client quota", status)
	}
	if status := begin("10.0.2.100:1234", "2001:db8::20"); status != 200 {
		t.Fatal("second client must have separate quota", status)
	}
	for i := 0; i < 10; i++ {
		if status := begin("203.0.113.9:1234", "198.51.100.11"); status != 200 {
			t.Fatal("direct client", i, status)
		}
	}
	if status := begin("203.0.113.9:1234", "198.51.100.12"); status != 429 {
		t.Fatal("untrusted header bypassed quota", status)
	}
}

func TestTrustedProxyRejectsAmbiguousAddresses(t *testing.T) {
	for _, forwarded := range []string{"198.51.100.1, 198.51.100.2", "not-an-address", "198.51.100.1:8080", ""} {
		handler := withTrustedProxy(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.RemoteAddr != "127.0.0.1:1234" {
				t.Errorf("ambiguous header changed peer: %q", forwarded)
			}
		}), []netip.Prefix{netip.MustParsePrefix("127.0.0.1/32")})
		request := httptest.NewRequest(http.MethodGet, "http://petlink.test", nil)
		request.RemoteAddr = "127.0.0.1:1234"
		request.Header.Set("X-Forwarded-For", forwarded)
		handler.ServeHTTP(httptest.NewRecorder(), request)
	}
	handler := withTrustedProxy(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.RemoteAddr != "127.0.0.1:1234" {
			t.Error("duplicate headers changed peer")
		}
	}), []netip.Prefix{netip.MustParsePrefix("127.0.0.1/32")})
	request := httptest.NewRequest(http.MethodGet, "http://petlink.test", nil)
	request.RemoteAddr = "127.0.0.1:1234"
	request.Header.Add("X-Forwarded-For", "198.51.100.1")
	request.Header.Add("X-Forwarded-For", "198.51.100.2")
	handler.ServeHTTP(httptest.NewRecorder(), request)
}
