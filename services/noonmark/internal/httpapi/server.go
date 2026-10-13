package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/quboliu/noonmark/services/noonmark/internal/core"
	"github.com/quboliu/noonmark/services/noonmark/internal/store"
)

type Config struct {
	PublicOrigin   string
	WebDir         string
	Version        string
	TrustedProxies []*net.IPNet
}

type Server struct {
	store        *store.Store
	config       Config
	origin       *url.URL
	loginMu      sync.Mutex
	attempts     []time.Time
	loginSlots   chan struct{}
	commandSlots chan struct{}
	streams      chan struct{}
	backups      chan struct{}
}

func New(database *store.Store, config Config) (http.Handler, error) {
	origin, err := url.Parse(config.PublicOrigin)
	if err != nil || origin.User != nil || origin.RawQuery != "" || origin.Fragment != "" || (origin.Path != "" && origin.Path != "/") || origin.Host == "" {
		return nil, errors.New("ORIGIN_INVALID")
	}
	if origin.Scheme != "https" && !(origin.Scheme == "http" && loopback(origin.Hostname())) {
		return nil, errors.New("HTTPS_REQUIRED")
	}
	if strings.TrimSuffix(config.PublicOrigin, "/") != origin.Scheme+"://"+origin.Host {
		return nil, errors.New("ORIGIN_INVALID")
	}
	if !database.OwnerInitialized(context.Background()) {
		return nil, errors.New("OWNER_REQUIRED")
	}
	web, err := filepath.Abs(config.WebDir)
	if err != nil {
		return nil, errors.New("ASSETS_UNAVAILABLE")
	}
	info, err := os.Stat(filepath.Join(web, "index.html"))
	if err != nil || !info.Mode().IsRegular() {
		return nil, errors.New("ASSETS_UNAVAILABLE")
	}
	config.WebDir = web
	return &Server{store: database, config: config, origin: origin, loginSlots: make(chan struct{}, 2), commandSlots: make(chan struct{}, 32), streams: make(chan struct{}, 32), backups: make(chan struct{}, 1)}, nil
}

func loopback(host string) bool {
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'")
	w.Header().Set("Cache-Control", "no-store")
	if r.Method == http.MethodGet && r.URL.Path == "/healthz" {
		ctx, cancel := context.WithTimeout(r.Context(), time.Second)
		defer cancel()
		if s.store.Health(ctx) != nil {
			writeError(w, 503, "STORAGE_UNAVAILABLE")
			return
		}
		writeJSON(w, 200, map[string]bool{"ok": true})
		return
	}
	if !strings.EqualFold(r.Host, s.origin.Host) {
		writeError(w, 421, "ORIGIN_MISMATCH")
		return
	}
	if s.origin.Scheme == "http" && !s.localOrTrustedPeer(r) {
		writeError(w, http.StatusForbidden, "HTTPS_REQUIRED")
		return
	}
	if s.origin.Scheme == "https" && r.TLS == nil && !s.trustedTLS(r) {
		writeError(w, 400, "HTTPS_REQUIRED")
		return
	}
	if value := r.Header.Get("Origin"); value != "" && value != strings.TrimSuffix(s.config.PublicOrigin, "/") {
		writeError(w, 403, "ORIGIN_MISMATCH")
		return
	}
	if r.Header.Get("Sec-Fetch-Site") == "cross-site" {
		writeError(w, 403, "ORIGIN_MISMATCH")
		return
	}
	if !strings.HasPrefix(r.URL.Path, "/api/") {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			writeError(w, 405, "METHOD_NOT_ALLOWED")
			return
		}
		s.static(w, r)
		return
	}
	if r.URL.Path == "/api/v1/auth/login" && r.Method == http.MethodPost {
		s.login(w, r)
		return
	}
	if r.URL.Path == "/api/v1/info" && r.Method == http.MethodGet {
		writeJSON(w, 200, map[string]any{"initialized": true, "version": s.config.Version})
		return
	}
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok {
		writeError(w, 401, "AUTH_REQUIRED")
		return
	}
	if _, err := s.store.Authenticate(r.Context(), token); err != nil {
		writeError(w, 401, "AUTH_REQUIRED")
		return
	}
	r = r.WithContext(store.WithSession(r.Context(), token))
	switch {
	case r.Method == http.MethodPost && r.URL.Path == "/api/v1/auth/logout":
		if err := s.store.Logout(r.Context(), token); err != nil {
			writeError(w, 503, "STORAGE_UNAVAILABLE")
			return
		}
		writeJSON(w, 200, map[string]bool{"ok": true})
	case r.Method == http.MethodGet && r.URL.Path == "/api/v1/snapshot":
		select {
		case s.commandSlots <- struct{}{}:
			defer func() { <-s.commandSlots }()
		default:
			writeError(w, 503, "BUSY")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
		defer cancel()
		snapshot, err := s.store.Snapshot(ctx)
		if err != nil {
			s.error(w, err)
			return
		}
		writeJSON(w, 200, snapshot)
	case r.Method == http.MethodPost && r.URL.Path == "/api/v1/commands":
		select {
		case s.commandSlots <- struct{}{}:
			defer func() { <-s.commandSlots }()
		default:
			writeError(w, 503, "BUSY")
			return
		}
		var command core.Command
		if err := decode(w, r, &command, 1<<20); err != nil {
			writeError(w, 400, "INVALID_REQUEST")
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
		defer cancel()
		receipt, err := s.store.Execute(ctx, command)
		if err != nil {
			s.error(w, err)
			return
		}
		writeJSON(w, 200, receipt)
	case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/api/v1/commands/"):
		select {
		case s.commandSlots <- struct{}{}:
			defer func() { <-s.commandSlots }()
		default:
			writeError(w, 503, "BUSY")
			return
		}
		id := strings.TrimPrefix(r.URL.Path, "/api/v1/commands/")
		if len(id) != 36 {
			writeError(w, 400, "INVALID_REQUEST")
			return
		}
		receipt, err := s.store.Receipt(r.Context(), id)
		if err != nil {
			s.error(w, err)
			return
		}
		writeJSON(w, 200, receipt)
	case r.Method == http.MethodGet && r.URL.Path == "/api/v1/events":
		s.events(w, r, token)
	case r.Method == http.MethodPost && r.URL.Path == "/api/v1/backups":
		s.backup(w, r)
	default:
		writeError(w, 404, "NOT_FOUND")
	}
}

func (s *Server) trustedTLS(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	for _, network := range s.config.TrustedProxies {
		if network.Contains(ip) && r.Header.Get("X-Forwarded-Proto") == "https" {
			return true
		}
	}
	return false
}

func (s *Server) localOrTrustedPeer(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return false
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	if ip.IsLoopback() {
		return true
	}
	for _, network := range s.config.TrustedProxies {
		if network.Contains(ip) {
			return true
		}
	}
	return false
}

func (s *Server) login(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Password string `json:"password"`
	}
	if err := decode(w, r, &input, 4096); err != nil {
		writeError(w, 400, "INVALID_REQUEST")
		return
	}
	s.loginMu.Lock()
	now := time.Now()
	kept := s.attempts[:0]
	for _, when := range s.attempts {
		if now.Sub(when) < time.Minute {
			kept = append(kept, when)
		}
	}
	s.attempts = kept
	if len(s.attempts) >= 10 {
		s.loginMu.Unlock()
		w.Header().Set("Retry-After", "60")
		writeError(w, 429, "RATE_LIMITED")
		return
	}
	s.attempts = append(s.attempts, now)
	s.loginMu.Unlock()
	select {
	case s.loginSlots <- struct{}{}:
		defer func() { <-s.loginSlots }()
	default:
		writeError(w, 429, "RATE_LIMITED")
		return
	}
	session, err := s.store.Login(r.Context(), input.Password)
	if err != nil {
		if errors.Is(err, store.ErrCredentials) {
			writeError(w, 401, "INVALID_CREDENTIALS")
		} else {
			s.error(w, err)
		}
		return
	}
	writeJSON(w, 200, session)
}

func (s *Server) backup(w http.ResponseWriter, r *http.Request) {
	select {
	case s.backups <- struct{}{}:
		defer func() { <-s.backups }()
	default:
		writeError(w, 503, "BUSY")
		return
	}
	var input struct {
		Password   string `json:"password"`
		Passphrase string `json:"passphrase"`
	}
	if err := decode(w, r, &input, 4096); err != nil {
		writeError(w, 400, "INVALID_REQUEST")
		return
	}
	if err := s.store.VerifyOwnerPassword(r.Context(), input.Password); err != nil {
		writeError(w, 401, "INVALID_CREDENTIALS")
		return
	}
	var output bytes.Buffer
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Minute)
	defer cancel()
	if _, err := s.store.Backup(ctx, &output, input.Passphrase); err != nil {
		s.error(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", `attachment; filename="noonmark-instance.noonmarkbackup"`)
	w.Header().Set("Content-Length", strconv.Itoa(output.Len()))
	w.WriteHeader(200)
	_, _ = output.WriteTo(w)
}

func (s *Server) events(w http.ResponseWriter, r *http.Request, token string) {
	select {
	case s.streams <- struct{}{}:
		defer func() { <-s.streams }()
	default:
		writeError(w, 503, "BUSY")
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, 500, "STREAM_UNAVAILABLE")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("X-Accel-Buffering", "no")
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	last := ""
	beats := 0
	for {
		if _, err := s.store.Authenticate(r.Context(), token); err != nil {
			return
		}
		sequence, err := s.store.CurrentSequence(r.Context())
		if err != nil {
			return
		}
		controller := http.NewResponseController(w)
		_ = controller.SetWriteDeadline(time.Now().Add(5 * time.Second))
		if sequence != last {
			payload, _ := json.Marshal(map[string]string{"sequence": sequence})
			if _, err = fmt.Fprintf(w, "event: change\ndata: %s\n\n", payload); err != nil {
				return
			}
			last = sequence
			flusher.Flush()
		} else if beats%10 == 0 {
			if _, err = io.WriteString(w, ": heartbeat\n\n"); err != nil {
				return
			}
			flusher.Flush()
		}
		_ = controller.SetWriteDeadline(time.Time{})
		beats++
		select {
		case <-r.Context().Done():
			return
		case <-ticker.C:
		}
	}
}

func (s *Server) static(w http.ResponseWriter, r *http.Request) {
	rel := strings.TrimPrefix(r.URL.Path, "/")
	if rel == "" {
		rel = "index.html"
	}
	if strings.Contains(rel, "\\") || !filepath.IsLocal(rel) {
		http.NotFound(w, r)
		return
	}
	full := filepath.Join(s.config.WebDir, rel)
	resolved, err := filepath.EvalSymlinks(full)
	if err != nil {
		if filepath.Ext(rel) == "" {
			resolved = filepath.Join(s.config.WebDir, "index.html")
		} else {
			http.NotFound(w, r)
			return
		}
	}
	inside, err := filepath.Rel(s.config.WebDir, resolved)
	if err != nil || !filepath.IsLocal(inside) {
		http.NotFound(w, r)
		return
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.Mode().IsRegular() {
		http.NotFound(w, r)
		return
	}
	if strings.HasPrefix(inside, "assets"+string(filepath.Separator)) {
		w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
	}
	http.ServeFile(w, r, resolved)
}

func decode(w http.ResponseWriter, r *http.Request, destination any, limit int64) error {
	media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || media != "application/json" {
		return errors.New("INVALID_REQUEST")
	}
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, limit))
	if err != nil {
		return err
	}
	if err = uniqueJSON(data); err != nil {
		return err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err = decoder.Decode(destination); err != nil {
		return err
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return errors.New("INVALID_REQUEST")
	}
	return nil
}

// 拒绝重复 JSON 字段，避免校验与幂等摘要对同一请求作不同解释。
func uniqueJSON(data []byte) error {
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	var value func(int) error
	value = func(depth int) error {
		if depth > 32 {
			return errors.New("INVALID_REQUEST")
		}
		t, err := d.Token()
		if err != nil {
			return err
		}
		delim, ok := t.(json.Delim)
		if !ok {
			return nil
		}
		switch delim {
		case '{':
			keys := map[string]bool{}
			for d.More() {
				key, err := d.Token()
				if err != nil {
					return err
				}
				name, ok := key.(string)
				// 协议字段固定为 ASCII snake_case；拒绝 Go JSON 的大小写与
				// Unicode SimpleFold 别名，避免 Password／paſsword 覆盖 password。
				if !ok || name == "" || keys[name] {
					return errors.New("INVALID_REQUEST")
				}
				for _, char := range name {
					if !(char >= 'a' && char <= 'z') && !(char >= '0' && char <= '9') && char != '_' {
						return errors.New("INVALID_REQUEST")
					}
				}
				keys[name] = true
				if err = value(depth + 1); err != nil {
					return err
				}
			}
		case '[':
			for d.More() {
				if err = value(depth + 1); err != nil {
					return err
				}
			}
		default:
			return errors.New("INVALID_REQUEST")
		}
		_, err = d.Token()
		return err
	}
	if err := value(0); err != nil {
		return err
	}
	if _, err := d.Token(); err != io.EOF {
		return errors.New("INVALID_REQUEST")
	}
	return nil
}

func (s *Server) error(w http.ResponseWriter, err error) {
	if errors.Is(err, store.ErrPassword) {
		writeError(w, 400, "PASSWORD_INVALID")
		return
	}
	if errors.Is(err, store.ErrCredentials) {
		writeError(w, 401, "AUTH_REQUIRED")
		return
	}
	code := core.ErrorCode(err)
	status := 400
	switch code {
	case "NOT_FOUND", "COMMAND_NOT_FOUND":
		status = 404
	case "VERSION_CONFLICT", "DAY_LOCKED", "INSTANCE_CHANGED", "DATASET_INACTIVE", "IDEMPOTENCY_MISMATCH":
		status = 409
	case "BUSY", "STORAGE_FULL", "STORAGE_UNAVAILABLE":
		status = 503
	case "STORAGE_FAILURE", "REQUEST_CANCELLED":
		status = 503
	case "INTERNAL":
		status = 500
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		code = "REQUEST_UNCONFIRMED"
		status = 503
	}
	writeError(w, status, code)
}

func writeError(w http.ResponseWriter, status int, code string) {
	writeJSON(w, status, map[string]string{"code": code})
}
func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func ParseProxy(value string) (*net.IPNet, error) {
	_, network, err := net.ParseCIDR(value)
	if err != nil {
		return nil, errors.New("PROXY_INVALID")
	}
	return network, nil
}

func Port(address string) int {
	_, port, err := net.SplitHostPort(address)
	if err != nil {
		return 0
	}
	n, _ := strconv.Atoi(port)
	return n
}
