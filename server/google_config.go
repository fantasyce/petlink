package main

import (
	"encoding/json"
	"io"
	"os"
	"strings"
)

func loadGoogleConfig(path string) (GoogleConfig, error) {
	if path == "" {
		return GoogleConfig{}, ErrGoogleUnavailable
	}
	info, e := os.Lstat(path)
	if e != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() > 8192 {
		return GoogleConfig{}, ErrGoogleUnavailable
	}
	f, e := os.Open(path)
	if e != nil {
		return GoogleConfig{}, ErrGoogleUnavailable
	}
	defer f.Close()
	var in struct {
		ClientID     string `json:"client_id"`
		ClientSecret string `json:"client_secret"`
	}
	d := json.NewDecoder(io.LimitReader(f, 8193))
	d.DisallowUnknownFields()
	if d.Decode(&in) != nil || !strings.HasSuffix(in.ClientID, ".apps.googleusercontent.com") || len(in.ClientID) > 256 || len(in.ClientSecret) > 1024 {
		return GoogleConfig{}, ErrGoogleUnavailable
	}
	if d.Decode(new(any)) != io.EOF {
		return GoogleConfig{}, ErrGoogleUnavailable
	}
	return GoogleConfig{ClientID: in.ClientID, ClientSecret: in.ClientSecret}, nil
}
