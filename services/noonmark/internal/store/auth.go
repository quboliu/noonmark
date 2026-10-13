package store

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"golang.org/x/crypto/argon2"
)

var (
	ErrCredentials = errors.New("AUTH_REQUIRED")
	ErrPassword    = errors.New("PASSWORD_INVALID")
	ErrOwnerExists = errors.New("OWNER_EXISTS")
)

type Session struct {
	Token     string `json:"token"`
	ExpiresAt int64  `json:"expires_at"`
}

type sessionContextKey struct{}

func WithSession(ctx context.Context, token string) context.Context {
	return context.WithValue(ctx, sessionContextKey{}, tokenDigest(token))
}

func (s *Store) validateSessionTx(ctx context.Context, tx *sql.Tx) error {
	digest, ok := ctx.Value(sessionContextKey{}).(string)
	if !ok {
		return nil
	}
	var owner string
	if err := tx.QueryRowContext(ctx, "SELECT s.owner_id FROM sessions s JOIN instance_state i ON s.owner_id=i.owner_id WHERE s.token_hash=? AND s.expires_at>?", digest, time.Now().Unix()).Scan(&owner); err != nil {
		return ErrCredentials
	}
	return nil
}

func ValidatePassword(password string) error {
	if !utf8.ValidString(password) || len([]rune(password)) < 12 || len(password) > 1024 {
		return ErrPassword
	}
	return nil
}

func passwordHash(password string) (string, error) {
	if err := ValidatePassword(password); err != nil {
		return "", err
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key := argon2.IDKey([]byte(password), salt, 3, 64*1024, 1, 32)
	return "$argon2id$v=19$m=65536,t=3,p=1$" + base64.RawStdEncoding.EncodeToString(salt) + "$" + base64.RawStdEncoding.EncodeToString(key), nil
}

func verifyPassword(password, encoded string) bool {
	// 参数只接受本服务写入的固定配置，损坏 verifier 不能请求无界内存。
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[1] != "argon2id" || parts[2] != "v=19" || parts[3] != "m=65536,t=3,p=1" || len(password) > 1024 {
		return false
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil || len(salt) != 16 {
		return false
	}
	want, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil || len(want) != 32 {
		return false
	}
	got := argon2.IDKey([]byte(password), salt, 3, 64*1024, 1, 32)
	return subtle.ConstantTimeCompare(got, want) == 1
}

func (s *Store) InitializeOwner(ctx context.Context, password string) error {
	hash, err := passwordHash(password)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var count int
	if err := s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM owners").Scan(&count); err != nil {
		return err
	}
	if count != 0 {
		return ErrOwnerExists
	}
	_, err = s.db.ExecContext(ctx, "INSERT INTO owners(id,password_hash) SELECT owner_id,? FROM instance_state WHERE id=1", hash)
	return err
}

func (s *Store) OwnerInitialized(ctx context.Context) bool {
	var count int
	err := s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM owners o JOIN instance_state i ON o.id=i.owner_id WHERE i.id=1").Scan(&count)
	return err == nil && count == 1
}

func (s *Store) VerifyOwnerPassword(ctx context.Context, password string) error {
	var hash string
	if err := s.db.QueryRowContext(ctx, "SELECT o.password_hash FROM owners o JOIN instance_state i ON o.id=i.owner_id WHERE i.id=1").Scan(&hash); err != nil || !verifyPassword(password, hash) {
		return ErrCredentials
	}
	return nil
}

func (s *Store) Login(ctx context.Context, password string) (Session, error) {
	var owner, hash string
	if err := s.db.QueryRowContext(ctx, "SELECT o.id,o.password_hash FROM owners o JOIN instance_state i ON o.id=i.owner_id WHERE i.id=1").Scan(&owner, &hash); err != nil {
		return Session{}, ErrCredentials
	}
	if !verifyPassword(password, hash) {
		return Session{}, ErrCredentials
	}
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return Session{}, err
	}
	token := base64.RawURLEncoding.EncodeToString(bytes)
	now := time.Now().Unix()
	expires := now + int64((12*time.Hour)/time.Second)
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Session{}, err
	}
	defer tx.Rollback()
	// 密码可能在验证期间被重置；不能为旧 verifier 再签发会话。
	var current string
	if err = tx.QueryRowContext(ctx, "SELECT password_hash FROM owners WHERE id=?", owner).Scan(&current); err != nil || current != hash {
		return Session{}, ErrCredentials
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM sessions WHERE expires_at<=?", now); err != nil {
		return Session{}, err
	}
	var count int
	if err = tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM sessions").Scan(&count); err != nil {
		return Session{}, err
	}
	if count >= 100 {
		return Session{}, errors.New("SESSION_LIMIT")
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO sessions(token_hash,owner_id,expires_at,created_at) VALUES(?,?,?,?)", tokenDigest(token), owner, expires, now); err != nil {
		return Session{}, err
	}
	if err = tx.Commit(); err != nil {
		return Session{}, err
	}
	return Session{Token: token, ExpiresAt: expires}, nil
}

func tokenDigest(token string) string {
	digest := sha256.Sum256([]byte(token))
	return hex.EncodeToString(digest[:])
}

func (s *Store) Authenticate(ctx context.Context, token string) (string, error) {
	if len(token) != 43 {
		return "", ErrCredentials
	}
	var owner string
	err := s.db.QueryRowContext(ctx, "SELECT s.owner_id FROM sessions s JOIN instance_state i ON s.owner_id=i.owner_id WHERE s.token_hash=? AND s.expires_at>?", tokenDigest(token), time.Now().Unix()).Scan(&owner)
	if err != nil {
		return "", ErrCredentials
	}
	return owner, nil
}

func (s *Store) Logout(ctx context.Context, token string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, err := s.db.ExecContext(ctx, "DELETE FROM sessions WHERE token_hash=?", tokenDigest(token))
	return err
}

func (s *Store) ResetPassword(ctx context.Context, password string) error {
	hash, err := passwordHash(password)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "UPDATE owners SET password_hash=? WHERE id=(SELECT owner_id FROM instance_state WHERE id=1)", hash); err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM sessions"); err != nil {
		return err
	}
	return tx.Commit()
}

// Health 不读取业务正文，只证明数据库连接仍可用。
func (s *Store) Health(ctx context.Context) error {
	var one int
	if err := s.db.QueryRowContext(ctx, "SELECT 1").Scan(&one); err != nil {
		return errors.New("STORAGE_UNAVAILABLE")
	}
	if one != 1 {
		return errors.New("STORAGE_UNAVAILABLE")
	}
	return nil
}

func (s *Store) CurrentSequence(ctx context.Context) (string, error) {
	var sequence int64
	err := s.db.QueryRowContext(ctx, "SELECT sequence FROM instance_state WHERE id=1").Scan(&sequence)
	return strconv.FormatInt(sequence, 10), err
}
