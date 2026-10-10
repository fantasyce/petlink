package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"os"
	"os/exec"
	"testing"
	"time"
)

func TestAvatarSwiftHTTPWireRoundTrip(t *testing.T) {
	binary := os.Getenv("PETLINK_AVATAR_WIRE_TEST")
	if binary == "" {
		t.Skip("Swift peer is required; scripts/build.sh supplies PETLINK_AVATAR_WIRE_TEST")
	}
	s, rt, owner, requester, _, _ := connectAvatarFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, binary, owner.AccountID, requester.AccountID)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err = cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer cmd.Process.Kill()
	var fixture struct {
		OwnerAgreement, OwnerSigning, RequesterAgreement, RequesterSigning string
		Cases                                                              []struct{ Request, Result AvatarEnvelope }
	}
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 4096), 256*1024)
	if !scanner.Scan() {
		t.Fatal("Swift peer produced no fixture")
	}
	if err = json.Unmarshal(scanner.Bytes(), &fixture); err != nil {
		t.Fatal(err)
	}
	if len(fixture.Cases) != 5 {
		t.Fatal("missing fractional timestamp cases")
	}
	if _, err = s.RegisterDeviceKeys(owner.AccountID, "owner-device", fixture.OwnerAgreement, fixture.OwnerSigning); err != nil {
		t.Fatal(err)
	}
	if _, err = s.RegisterDeviceKeys(requester.AccountID, "requester-device", fixture.RequesterAgreement, fixture.RequesterSigning); err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(SocialHandlerWithRuntime(s, rt))
	defer ts.Close()
	var returned []AvatarEnvelope
	for _, c := range fixture.Cases {
		resp, out := avatarAPI(t, ts.Client(), "POST", ts.URL+"/v3/avatar/tasks", requester.AccessToken, "submit-"+c.Request.TaskID, map[string]any{"owner_id": owner.AccountID, "envelope": c.Request})
		if resp.StatusCode != 201 {
			t.Fatalf("Swift request rejected: %d %v", resp.StatusCode, out)
		}
		snap, err := rt.Snapshot(owner.AccountID, "owner-device", "owner-session", "sync")
		if err != nil {
			t.Fatal(err)
		}
		for _, view := range snap.AvatarTasks {
			if view.Task.ID == c.Request.TaskID && view.Request != nil {
				returned = append(returned, *view.Request)
			}
		}
		for _, action := range []string{"respond", "start", "complete"} {
			body := map[string]any{"accept": true}
			if action == "complete" {
				body = map[string]any{"envelope": c.Result}
			}
			resp, out = avatarAPI(t, ts.Client(), "POST", ts.URL+"/v3/avatar/tasks/"+c.Request.TaskID+"/"+action, owner.AccessToken, action+"-"+c.Request.TaskID, body)
			if resp.StatusCode != 200 {
				t.Fatalf("%s rejected: %d %v", action, resp.StatusCode, out)
			}
		}
		snap, err = rt.Snapshot(requester.AccountID, "requester-device", "requester-session", "sync")
		if err != nil {
			t.Fatal(err)
		}
		for _, view := range snap.AvatarTasks {
			if view.Task.ID == c.Request.TaskID && view.Result != nil {
				returned = append(returned, *view.Result)
			}
		}
	}
	if err = json.NewEncoder(stdin).Encode(map[string]any{"envelopes": returned}); err != nil {
		t.Fatal(err)
	}
	stdin.Close()
	if err = cmd.Wait(); err != nil {
		t.Fatalf("Swift could not verify/decrypt relayed envelopes: %v %s", err, stderr.String())
	}
}
