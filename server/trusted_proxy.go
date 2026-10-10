package main

import (
	"net"
	"net/http"
	"net/netip"
)

// Only an explicitly configured peer may supply the single client address that
// our gateway overwrites. Direct clients and ambiguous forwarding chains retain
// their socket address, so spoofed headers cannot bypass per-client quotas.
func withTrustedProxy(next http.Handler, trusted []netip.Prefix) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		peer, parseErr := netip.ParseAddr(host)
		if err == nil && parseErr == nil {
			for _, prefix := range trusted {
				if !prefix.Contains(peer.Unmap()) {
					continue
				}
				values := r.Header.Values("X-Forwarded-For")
				if len(values) == 1 {
					if client, err := netip.ParseAddr(values[0]); err == nil && client.Zone() == "" {
						r = r.Clone(r.Context())
						r.RemoteAddr = net.JoinHostPort(client.Unmap().String(), "0")
					}
				}
				break
			}
		}
		next.ServeHTTP(w, r)
	})
}
