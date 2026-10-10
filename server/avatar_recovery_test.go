package main

import (
	"path/filepath"
	"testing"
	"time"
)

func TestOpenSocialStoreFailsNonterminalAvatarTasksAfterRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "petlink.db")
	s, err := OpenSocialStore(path)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UnixMilli()
	_, err = s.db.Exec(`INSERT INTO avatar_tasks(id,owner_id,requester_id,requester_device_id,owner_device_id,provider,state,visit_revision,policy_revision,request_digest,created_at,expires_at) VALUES('dlg_restart','owner','peer','pd','od','claude','running',1,1,'digest',?,?)`, now, now+60000)
	if err != nil {
		t.Fatal(err)
	}
	s.Close()
	s, err = OpenSocialStore(path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	task, err := s.AvatarTask("dlg_restart")
	if err != nil || task.State != AvatarFailed || task.ErrorCode != "SERVER_RESTARTED" {
		t.Fatalf("task=%#v err=%v", task, err)
	}
}
