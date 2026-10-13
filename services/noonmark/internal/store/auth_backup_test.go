package store

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/quboliu/noonmark/services/noonmark/internal/core"
)

const ownerFixturePassword = "test-only owner passphrase 124"
const backupFixturePassword = "test-only backup passphrase 456"

func securedFixture(t *testing.T) *Store {
	t.Helper()
	ctx := context.Background()
	s, err := Init(ctx, filepath.Join(t.TempDir(), "instance"), "Asia/Singapore")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	if err = s.InitializeOwner(ctx, ownerFixturePassword); err != nil {
		t.Fatal(err)
	}
	if err = s.InitializeKey(); err != nil {
		t.Fatal(err)
	}
	return s
}

func securityCommand(t *testing.T, s *Store) core.Command {
	t.Helper()
	state, err := s.Snapshot(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	return core.Command{InstanceID: state.InstanceID, InstanceEpoch: state.InstanceEpoch, DatasetID: state.DatasetID, CommandID: uuid(), SchemaVersion: 1, Type: "CreateTask", ExpectedRevision: "0", Payload: core.Payload{Title: "隔离测试任务", Date: state.Today}}
}

func TestOwnerSessionsAndRevokedWriter(t *testing.T) {
	s := securedFixture(t)
	ctx := context.Background()
	if _, err := s.Login(ctx, "incorrect password"); !errors.Is(err, ErrCredentials) {
		t.Fatal("incorrect credential accepted")
	}
	session, err := s.Login(ctx, ownerFixturePassword)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = s.Authenticate(ctx, session.Token); err != nil {
		t.Fatal(err)
	}
	var raw string
	if err = s.db.QueryRow("SELECT token_hash FROM sessions").Scan(&raw); err != nil {
		t.Fatal(err)
	}
	if raw == session.Token || len(raw) != 64 {
		t.Fatal("raw token stored")
	}
	command := securityCommand(t, s)
	revokedCtx := WithSession(ctx, session.Token)
	if err = s.Logout(ctx, session.Token); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Execute(revokedCtx, command); !errors.Is(err, ErrCredentials) {
		t.Fatalf("revoked queued writer accepted: %v", err)
	}
	state, err := s.Snapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(state.Chains) != 0 {
		t.Fatal("revoked writer changed facts")
	}
	if err = s.InitializeOwner(ctx, ownerFixturePassword); !errors.Is(err, ErrOwnerExists) {
		t.Fatal("owner replaced")
	}
}

func TestPasswordResetRevokesEverySession(t *testing.T) {
	s := securedFixture(t)
	ctx := context.Background()
	session, err := s.Login(ctx, ownerFixturePassword)
	if err != nil {
		t.Fatal(err)
	}
	if err = s.ResetPassword(ctx, "another fixture password 789"); err != nil {
		t.Fatal(err)
	}
	if _, err = s.Authenticate(ctx, session.Token); !errors.Is(err, ErrCredentials) {
		t.Fatal("old session still valid")
	}
	if _, err = s.Login(ctx, ownerFixturePassword); !errors.Is(err, ErrCredentials) {
		t.Fatal("old password still valid")
	}
	if _, err = s.Login(ctx, "another fixture password 789"); err != nil {
		t.Fatal(err)
	}
}

func TestEncryptedBackupRestoresFactsAndFencesOldRequests(t *testing.T) {
	s := securedFixture(t)
	ctx := context.Background()
	command := securityCommand(t, s)
	if _, err := s.Execute(ctx, command); err != nil {
		t.Fatal(err)
	}
	session, err := s.Login(ctx, ownerFixturePassword)
	if err != nil {
		t.Fatal(err)
	}
	var encrypted bytes.Buffer
	manifest, err := s.Backup(ctx, &encrypted, backupFixturePassword)
	if err != nil {
		t.Fatal(err)
	}
	if manifest.Sequence != 1 {
		t.Fatalf("snapshot checkpoint %d", manifest.Sequence)
	}
	if bytes.Contains(encrypted.Bytes(), []byte(command.Payload.Title)) || bytes.Contains(encrypted.Bytes(), []byte(ownerFixturePassword)) {
		t.Fatal("plaintext in encrypted backup")
	}
	parent := t.TempDir()
	restored, err := Restore(ctx, filepath.Join(parent, "restored"), bytes.NewReader(encrypted.Bytes()), backupFixturePassword)
	if err != nil {
		t.Fatal(err)
	}
	defer restored.Close()
	state, err := restored.Snapshot(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(state.Chains) != 1 || state.Definitions[0].Title != command.Payload.Title || state.InstanceEpoch == command.InstanceEpoch {
		t.Fatal("restored facts or epoch incorrect")
	}
	if _, err = restored.Authenticate(ctx, session.Token); !errors.Is(err, ErrCredentials) {
		t.Fatal("backup resurrected old session")
	}
	if _, err = restored.Execute(ctx, command); core.ErrorCode(err) != "INSTANCE_CHANGED" {
		t.Fatalf("stale command accepted: %v", err)
	}
	if _, err = restored.Login(ctx, ownerFixturePassword); err != nil {
		t.Fatal(err)
	}
	if _, err = Restore(ctx, filepath.Join(parent, "restored"), bytes.NewReader(encrypted.Bytes()), backupFixturePassword); core.ErrorCode(err) != "RESTORE_TARGET_EXISTS" {
		t.Fatal("restore overwrote target")
	}
	damaged := append([]byte(nil), encrypted.Bytes()...)
	damaged[len(damaged)-1] ^= 1
	badRoot := filepath.Join(parent, "bad")
	if _, err = Restore(ctx, badRoot, bytes.NewReader(damaged), backupFixturePassword); err == nil {
		t.Fatal("corrupt encrypted stream accepted")
	}
	if _, err = os.Stat(badRoot); err == nil {
		if opened, err := Open(ctx, badRoot); err == nil {
			opened.Close()
			t.Fatal("incomplete restore served")
		}
	}
}

func TestMasterKeyMissingOrSymlinkFailsClosed(t *testing.T) {
	s := securedFixture(t)
	if err := s.ValidateKey(); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(s.root, "secrets/master.key")
	if err := os.Rename(path, path+".saved"); err != nil {
		t.Fatal(err)
	}
	if err := s.ValidateKey(); err == nil {
		t.Fatal("missing key accepted")
	}
	if err := os.Symlink(path+".saved", path); err != nil {
		t.Fatal(err)
	}
	if err := s.ValidateKey(); err == nil {
		t.Fatal("key symlink accepted")
	}
}
