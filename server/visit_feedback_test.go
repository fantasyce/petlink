package main

import (
	"testing"
	"time"
)

func TestRejectedVisitRemainsVisibleToRequester(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t, s, "feedback-a", "feedbacka", "a-device")
	b := registerTestUser(t, s, "feedback-b", "feedbackb", "b-device")
	makeFriends(t, s, a, b)
	request, err := s.RequestVisit(a.AccountID, b.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.RespondVisit(b.AccountID, request.ID, false); err != nil {
		t.Fatal(err)
	}
	out, err := s.RecentVisitRequests(a.AccountID)
	if err != nil || len(out) != 1 || out[0].Status != "rejected" {
		t.Fatalf("rejection vanished: %#v %v", out, err)
	}
	foreign, err := s.RecentVisitRequests(b.AccountID)
	if err != nil || len(foreign) != 0 {
		t.Fatalf("foreign history leaked: %#v %v", foreign, err)
	}
	pending, err := s.OutgoingVisitRequests(a.AccountID)
	if err != nil || len(pending) != 0 {
		t.Fatal("old client pending projection contains terminal result")
	}
	next, err := s.RequestVisit(a.AccountID, b.AccountID)
	if err != nil {
		t.Fatal(err)
	}
	out, err = s.RecentVisitRequests(a.AccountID)
	if err != nil || len(out) != 2 || out[0].ID != next.ID || out[0].Status != "pending" {
		t.Fatal("new application did not replace old result")
	}
	if err = s.CancelVisit(a.AccountID, next.ID); err != nil {
		t.Fatal(err)
	}
	out, err = s.RecentVisitRequests(a.AccountID)
	if err != nil || out[0].Status != "cancelled" {
		t.Fatal("cancel result missing")
	}
	if _, err = s.db.Exec(`UPDATE visit_requests SET created_at=? WHERE guest_id=?`, time.Now().Add(-25*time.Hour).UnixMilli(), a.AccountID); err != nil {
		t.Fatal(err)
	}
	out, err = s.RecentVisitRequests(a.AccountID)
	if err != nil || len(out) != 0 {
		t.Fatal("unbounded history retention")
	}
}
