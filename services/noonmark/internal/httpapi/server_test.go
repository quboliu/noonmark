package httpapi

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/quboliu/noonmark/services/noonmark/internal/store"
)

const ownerPassword = "test-owner-passphrase-734"

func realFixture(t *testing.T) (*store.Store, string) {
	t.Helper()
	root := t.TempDir()
	database, err := store.Init(context.Background(), filepath.Join(root, "data"), "Asia/Singapore")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = database.Close() })
	if err := database.InitializeOwner(context.Background(), ownerPassword); err != nil {
		t.Fatal(err)
	}
	if err := database.InitializeKey(); err != nil {
		t.Fatal(err)
	}
	web := filepath.Join(root, "web")
	if err := os.Mkdir(web, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(web, "index.html"), []byte("<!doctype html><title>Noonmark fixture</title>"), 0600); err != nil {
		t.Fatal(err)
	}
	return database, web
}

func handlerFor(t *testing.T, database *store.Store, web, origin string, proxies ...string) http.Handler {
	t.Helper()
	config := Config{PublicOrigin: origin, WebDir: web, Version: "test"}
	for _, value := range proxies {
		_, network, err := net.ParseCIDR(value)
		if err != nil {
			t.Fatal(err)
		}
		config.TrustedProxies = append(config.TrustedProxies, network)
	}
	handler, err := New(database, config)
	if err != nil {
		t.Fatal(err)
	}
	return handler
}

func request(handler http.Handler, method, target, body, token string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, target, strings.NewReader(body))
	r.RemoteAddr = "127.0.0.1:49000"
	r.Header.Set("Content-Type", "application/json")
	if token != "" {
		r.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, r)
	return w
}

func assertCode(t *testing.T, response *httptest.ResponseRecorder, status int, code string) {
	t.Helper()
	if response.Code != status {
		t.Fatalf("status = %d, want %d", response.Code, status)
	}
	var result struct {
		Code string `json:"code"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil || result.Code != code {
		t.Fatalf("error code = %q, want %q", result.Code, code)
	}
}

func TestHTTPAuthenticationOverRealSocket(t *testing.T) {
	database, web := realFixture(t)
	server := httptest.NewUnstartedServer(nil)
	origin := "http://" + server.Listener.Addr().String()
	server.Config.Handler = handlerFor(t, database, web, origin)
	server.Start()
	t.Cleanup(server.Close)
	call := func(method, path, body, token string) (int, []byte) {
		t.Helper()
		req, err := http.NewRequest(method, server.URL+path, strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Origin", origin)
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		response, err := server.Client().Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer response.Body.Close()
		data, err := io.ReadAll(response.Body)
		if err != nil {
			t.Fatal(err)
		}
		if response.Header.Get("Cache-Control") != "no-store" || response.Header.Get("Set-Cookie") != "" {
			t.Fatal("authenticated API must not cache or set cookies")
		}
		return response.StatusCode, data
	}
	if status, _ := call("GET", "/api/v1/snapshot", "", ""); status != 401 {
		t.Fatalf("anonymous snapshot = %d", status)
	}
	if status, _ := call("POST", "/api/v1/auth/login", `{"password":"wrong-password"}`, ""); status != 401 {
		t.Fatalf("wrong password = %d", status)
	}
	status, data := call("POST", "/api/v1/auth/login", `{"password":"`+ownerPassword+`"}`, "")
	var session store.Session
	if status != 200 || json.Unmarshal(data, &session) != nil || len(session.Token) < 40 {
		t.Fatal("valid login did not return a session")
	}
	if status, data = call("GET", "/api/v1/snapshot", "", session.Token); status != 200 || !bytes.Contains(data, []byte(`"timezone":"Asia/Singapore"`)) {
		t.Fatal("authenticated snapshot did not read the real instance")
	}
	if status, _ := call("POST", "/api/v1/auth/logout", "", session.Token); status != 200 {
		t.Fatalf("logout = %d", status)
	}
	if status, _ := call("GET", "/api/v1/snapshot", "", session.Token); status != 401 {
		t.Fatalf("revoked session still accepted: %d", status)
	}
}

func TestLoginRejectsAmbiguousJSONBeforeAuthentication(t *testing.T) {
	database, web := realFixture(t)
	handler := handlerFor(t, database, web, "http://127.0.0.1:8080")
	for name, body := range map[string]string{
		"duplicate":                `{"password":"wrong-password","password":"` + ownerPassword + `"}`,
		"escaped duplicate":        `{"password":"wrong-password","\u0070assword":"` + ownerPassword + `"}`,
		"case folded duplicate":    `{"password":"wrong-password","Password":"` + ownerPassword + `"}`,
		"unicode folded duplicate": `{"password":"wrong-password","pa\u017fsword":"` + ownerPassword + `"}`,
		"unknown":                  `{"password":"` + ownerPassword + `","extra":true}`,
		"trailing":                 `{"password":"` + ownerPassword + `"} {}`,
		"oversized":                `{"password":"` + strings.Repeat("x", 4096) + `"}`,
		"nested":                   `{"password":` + strings.Repeat("[", 40) + `0` + strings.Repeat("]", 40) + `}`,
	} {
		t.Run(name, func(t *testing.T) {
			assertCode(t, request(handler, "POST", "http://127.0.0.1:8080/api/v1/auth/login", body, ""), 400, "INVALID_REQUEST")
		})
	}
}

func TestTransportAndOriginBoundaries(t *testing.T) {
	database, web := realFixture(t)
	type check struct {
		name, origin, peer, host, browserOrigin, forwarded, fetchSite string
		proxy, tls                                                    bool
		status                                                        int
	}
	checks := []check{
		{name: "local", origin: "http://127.0.0.1:8080", peer: "127.0.0.1:1", status: 200},
		{name: "nonlocal forged loopback host", origin: "http://127.0.0.1:8080", peer: "192.0.2.12:1", status: 403},
		{name: "explicit bridge", origin: "http://127.0.0.1:8080", peer: "192.0.2.11:1", proxy: true, status: 200},
		{name: "bridge wrong address", origin: "http://127.0.0.1:8080", peer: "192.0.2.12:1", proxy: true, status: 403},
		{name: "host mismatch", origin: "http://127.0.0.1:8080", peer: "127.0.0.1:1", host: "untrusted.invalid", status: 421},
		{name: "origin mismatch", origin: "http://127.0.0.1:8080", peer: "127.0.0.1:1", browserOrigin: "https://untrusted.invalid", status: 403},
		{name: "cross site", origin: "http://127.0.0.1:8080", peer: "127.0.0.1:1", fetchSite: "cross-site", status: 403},
		{name: "direct tls", origin: "https://noonmark.example", peer: "192.0.2.12:1", tls: true, status: 200},
		{name: "https downgrade", origin: "https://noonmark.example", peer: "192.0.2.12:1", status: 400},
		{name: "forged forwarded proto", origin: "https://noonmark.example", peer: "192.0.2.12:1", forwarded: "https", status: 400},
		{name: "trusted tls proxy", origin: "https://noonmark.example", peer: "192.0.2.11:1", proxy: true, forwarded: "https", status: 200},
		{name: "trusted proxy without tls assertion", origin: "https://noonmark.example", peer: "192.0.2.11:1", proxy: true, status: 400},
		{name: "ambiguous forwarded chain", origin: "https://noonmark.example", peer: "192.0.2.11:1", proxy: true, forwarded: "https,http", status: 400},
	}
	for _, tc := range checks {
		t.Run(tc.name, func(t *testing.T) {
			var proxies []string
			if tc.proxy {
				proxies = []string{"192.0.2.11/32"}
			}
			handler := handlerFor(t, database, web, tc.origin, proxies...)
			req := httptest.NewRequest("GET", tc.origin+"/api/v1/info", nil)
			req.RemoteAddr = tc.peer
			req.TLS = nil
			if tc.tls {
				req.TLS = &tls.ConnectionState{}
			}
			if tc.host != "" {
				req.Host = tc.host
			}
			req.Header.Set("Origin", tc.browserOrigin)
			req.Header.Set("X-Forwarded-Proto", tc.forwarded)
			req.Header.Set("Sec-Fetch-Site", tc.fetchSite)
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, req)
			if response.Code != tc.status {
				t.Fatalf("status = %d, want %d", response.Code, tc.status)
			}
		})
	}
}

func TestStaticAssetsCannotEscapeRoot(t *testing.T) {
	database, web := realFixture(t)
	secret := filepath.Join(filepath.Dir(web), "outside.txt")
	if err := os.WriteFile(secret, []byte("outside-sentinel"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(secret, filepath.Join(web, "escape.txt")); err != nil {
		t.Fatal(err)
	}
	handler := handlerFor(t, database, web, "http://127.0.0.1:8080")
	for _, path := range []string{"/escape.txt", "/../outside.txt", "/missing.js"} {
		response := request(handler, "GET", "http://127.0.0.1:8080"+path, "", "")
		if response.Code != 404 || strings.Contains(response.Body.String(), "outside-sentinel") {
			t.Fatalf("asset escape accepted: %s", path)
		}
	}
	response := request(handler, "GET", "http://127.0.0.1:8080/today", "", "")
	if response.Code != 200 || !strings.Contains(response.Body.String(), "Noonmark fixture") {
		t.Fatal("SPA route did not return index")
	}
}
