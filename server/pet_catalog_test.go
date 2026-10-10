package main

import "testing"

func TestPetCatalogAppearanceKeepsIdentity(t *testing.T) {
	s := newTestSocial(t)
	a := registerTestUser(t,s,"catalog-invite","catalog","catalog-device")
	r := NewSocialRuntime(s)
	for style:=0;style<10;style++ {
		if err:=r.Style(a.AccountID,style);err!=nil {t.Fatalf("appearance %d rejected: %v",style,err)}
		var got int
		if err:=s.db.QueryRow("SELECT style FROM pets WHERE owner_id=?",a.AccountID).Scan(&got);err!=nil||got!=style {t.Fatal("appearance not persisted")}
		p,err:=s.Profile(a.AccountID)
		if err!=nil||p.FriendID!=a.FriendID {t.Fatal("appearance changed identity")}
	}
	for _,style:=range []int{-1,10,999} {if r.Style(a.AccountID,style)==nil {t.Fatal("unknown appearance accepted")}}
 id,_,err:=s.ResolveGoogle(GoogleIdentity{"https://accounts.google.com","catalog-new","catalog@example.invalid"},"New")
 if err!=nil {t.Fatal(err)}
 var style int
 if err=s.db.QueryRow("SELECT style FROM pets WHERE owner_id=?",id).Scan(&style);err!=nil||style!=8 {t.Fatal("new account must start with bread")}
}
