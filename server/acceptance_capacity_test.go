package main

import (
	"errors"
	"sync"
	"testing"
)

func TestAcceptanceConcurrentTrustedVisitsReserveOnlyThreeSeats(t *testing.T) {
	s := newTestSocial(t)
	host := registerTestUser(t, s, "capacity-host", "capacityhost", "host-device")
	guests := make([]AuthResult, 4)
	for i, name := range []string{"capa", "capb", "capc", "capd"} {
		guests[i] = registerTestUser(t, s, "invite-"+name, name, "device-"+name)
		makeFriends(t, s, host, guests[i])
		if err := s.SetContactPolicy(host.AccountID, guests[i].AccountID, ContactPolicy{Trusted: true}); err != nil {
			t.Fatal(err)
		}
	}
	start := make(chan struct{})
	results := make(chan error, 4)
	var wg sync.WaitGroup
	for _, guest := range guests {
		wg.Add(1)
		go func(id string) {
			defer wg.Done()
			<-start
			_, err := s.RequestVisit(id, host.AccountID)
			results <- err
		}(guest.AccountID)
	}
	close(start)
	wg.Wait()
	close(results)
	accepted, full := 0, 0
	for err := range results {
		if err == nil {
			accepted++
		} else if errors.Is(err, ErrHostFull) {
			full++
		} else {
			t.Fatalf("unexpected result: %v", err)
		}
	}
	if accepted != 3 || full != 1 {
		t.Fatalf("accepted=%d full=%d", accepted, full)
	}
	var reserved int
	if err := s.db.QueryRow(`SELECT count(*) FROM pets WHERE target_id=? AND phase='travel'`, host.AccountID).Scan(&reserved); err != nil {
		t.Fatal(err)
	}
	if reserved != 3 {
		t.Fatalf("in-flight reservations=%d", reserved)
	}
}
