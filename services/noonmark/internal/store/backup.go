package store

import (
	"archive/tar"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"time"

	"filippo.io/age"
	"github.com/mattn/go-sqlite3"
	"github.com/quboliu/noonmark/services/noonmark/internal/core"
)

const maxBackupBytes int64 = 256 << 20

type BackupManifest struct {
	Format         string `json:"format"`
	Schema         int    `json:"schema"`
	InstanceID     string `json:"instance_id"`
	DatasetID      string `json:"dataset_id"`
	Sequence       int64  `json:"sequence"`
	DatabaseSHA256 string `json:"database_sha256"`
	CreatedAt      string `json:"created_at"`
}

func (s *Store) InitializeKey() error {
	secrets := filepath.Join(s.root, "secrets")
	if err := os.Mkdir(secrets, 0700); err != nil {
		return core.Fail("KEY_DIRECTORY_EXISTS")
	}
	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return core.Fail("RANDOM_UNAVAILABLE")
	}
	f, err := os.OpenFile(filepath.Join(secrets, "master.key"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return core.Fail("KEY_WRITE_FAILED")
	}
	_, writeErr := f.Write(key)
	syncErr := f.Sync()
	closeErr := f.Close()
	clear(key)
	if writeErr != nil || syncErr != nil || closeErr != nil {
		return core.Fail("KEY_WRITE_FAILED")
	}
	if err = syncDirectory(secrets); err != nil {
		return err
	}
	return syncDirectory(s.root)
}

func (s *Store) ValidateKey() error { key, err := s.masterKey(); clear(key); return err }
func (s *Store) masterKey() ([]byte, error) {
	dir := filepath.Join(s.root, "secrets")
	resolved, err := safeRoot(dir)
	if err != nil || resolved != dir {
		return nil, core.Fail("KEY_UNAVAILABLE")
	}
	path := filepath.Join(dir, "master.key")
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || info.Size() != 32 {
		return nil, core.Fail("KEY_UNAVAILABLE")
	}
	key, err := os.ReadFile(path)
	if err != nil || len(key) != 32 {
		return nil, core.Fail("KEY_UNAVAILABLE")
	}
	return key, nil
}

func dbDSN(path string) string {
	u := url.URL{Scheme: "file", Path: path}
	q := u.Query()
	q.Set("mode", "rw")
	q.Set("_foreign_keys", "on")
	u.RawQuery = q.Encode()
	return u.String()
}

func (s *Store) backupDatabase(ctx context.Context, destination string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var pages, pageSize int64
	if err := s.db.QueryRowContext(ctx, "PRAGMA page_count").Scan(&pages); err != nil {
		return storageError(err)
	}
	if err := s.db.QueryRowContext(ctx, "PRAGMA page_size").Scan(&pageSize); err != nil {
		return storageError(err)
	}
	if pageSize <= 0 || pages < 0 || pages > maxBackupBytes/pageSize {
		return core.Fail("BACKUP_SIZE_LIMIT")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return storageError(err)
	}
	if err = s.validateSessionTx(ctx, tx); err != nil {
		tx.Rollback()
		return err
	}
	if err = tx.Rollback(); err != nil {
		return storageError(err)
	}
	f, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return core.Fail("BACKUP_TARGET_EXISTS")
	}
	if err = f.Close(); err != nil {
		return storageError(err)
	}
	dest, err := sql.Open("sqlite3", dbDSN(destination))
	if err != nil {
		return storageError(err)
	}
	defer dest.Close()
	dest.SetMaxOpenConns(1)
	sourceConn, err := s.db.Conn(ctx)
	if err != nil {
		return storageError(err)
	}
	defer sourceConn.Close()
	targetConn, err := dest.Conn(ctx)
	if err != nil {
		return storageError(err)
	}
	defer targetConn.Close()
	err = targetConn.Raw(func(target any) error {
		return sourceConn.Raw(func(source any) error {
			backup, err := target.(*sqlite3.SQLiteConn).Backup("main", source.(*sqlite3.SQLiteConn), "main")
			if err != nil {
				return err
			}
			finished := false
			defer func() {
				if !finished {
					_ = backup.Finish()
				}
			}()
			for {
				if err := ctx.Err(); err != nil {
					return err
				}
				done, err := backup.Step(128)
				if err != nil {
					return err
				}
				if done {
					break
				}
			}
			finished = true
			return backup.Finish()
		})
	})
	return storageError(err)
}

// Backup 输出 age 加密归档，不把 owner 密码或恢复密钥写入日志和 argv。
func (s *Store) Backup(ctx context.Context, output io.Writer, passphrase string) (BackupManifest, error) {
	var manifest BackupManifest
	if len(passphrase) < 12 || len(passphrase) > 1024 {
		return manifest, ErrPassword
	}
	key, err := s.masterKey()
	if err != nil {
		return manifest, err
	}
	defer clear(key)
	stage, err := os.MkdirTemp(s.root, ".backup-")
	if err != nil {
		return manifest, core.Fail("BACKUP_STAGING_FAILED")
	}
	defer os.RemoveAll(stage)
	database := filepath.Join(stage, "state.sqlite")
	if err = s.backupDatabase(ctx, database); err != nil {
		return manifest, err
	}
	db, err := sql.Open("sqlite3", dbDSN(database))
	if err != nil {
		return manifest, storageError(err)
	}
	var check string
	if err = db.QueryRowContext(ctx, "PRAGMA integrity_check").Scan(&check); err != nil || check != "ok" {
		db.Close()
		return manifest, core.Fail("INTEGRITY_FAILURE")
	}
	manifest.Format = "noonmark-instance-backup/1"
	manifest.Schema = schemaVersion
	manifest.CreatedAt = time.Now().UTC().Format(time.RFC3339)
	err = db.QueryRowContext(ctx, "SELECT instance_id,dataset_id,sequence FROM instance_state WHERE id=1").Scan(&manifest.InstanceID, &manifest.DatasetID, &manifest.Sequence)
	closeErr := db.Close()
	if err != nil || closeErr != nil {
		return manifest, core.Fail("BACKUP_SNAPSHOT_FAILED")
	}
	file, err := os.Open(database)
	if err != nil {
		return manifest, core.Fail("BACKUP_SNAPSHOT_FAILED")
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || info.Size() > maxBackupBytes {
		return manifest, core.Fail("BACKUP_SIZE_LIMIT")
	}
	hash := sha256.New()
	if _, err = io.Copy(hash, file); err != nil {
		return manifest, core.Fail("BACKUP_SNAPSHOT_FAILED")
	}
	manifest.DatabaseSHA256 = hex.EncodeToString(hash.Sum(nil))
	if _, err = file.Seek(0, io.SeekStart); err != nil {
		return manifest, core.Fail("BACKUP_SNAPSHOT_FAILED")
	}
	recipient, err := age.NewScryptRecipient(passphrase)
	if err != nil {
		return manifest, core.Fail("BACKUP_ENCRYPTION_FAILED")
	}
	encrypted, err := age.Encrypt(output, recipient)
	if err != nil {
		return manifest, core.Fail("BACKUP_ENCRYPTION_FAILED")
	}
	archive := tar.NewWriter(encrypted)
	meta, _ := json.Marshal(manifest)
	for _, entry := range []struct {
		name string
		data []byte
	}{{"manifest.json", meta}, {"master.key", key}} {
		if err = archive.WriteHeader(&tar.Header{Name: entry.name, Mode: 0600, Size: int64(len(entry.data)), Typeflag: tar.TypeReg}); err != nil {
			return manifest, core.Fail("BACKUP_WRITE_FAILED")
		}
		if _, err = archive.Write(entry.data); err != nil {
			return manifest, core.Fail("BACKUP_WRITE_FAILED")
		}
	}
	if err = archive.WriteHeader(&tar.Header{Name: "state.sqlite", Mode: 0600, Size: info.Size(), Typeflag: tar.TypeReg}); err != nil {
		return manifest, core.Fail("BACKUP_WRITE_FAILED")
	}
	if _, err = io.Copy(archive, file); err != nil {
		return manifest, core.Fail("BACKUP_WRITE_FAILED")
	}
	if err = archive.Close(); err != nil {
		return manifest, core.Fail("BACKUP_WRITE_FAILED")
	}
	if err = encrypted.Close(); err != nil {
		return manifest, core.Fail("BACKUP_WRITE_FAILED")
	}
	return manifest, nil
}

// Restore 只接收新目录。归档没有目录路径语义，所有文件名均固定白名单。
func Restore(ctx context.Context, dataDir string, input io.Reader, passphrase string) (*Store, error) {
	if len(passphrase) < 12 || len(passphrase) > 1024 {
		return nil, ErrPassword
	}
	identity, err := age.NewScryptIdentity(passphrase)
	if err != nil {
		return nil, core.Fail("BACKUP_INVALID")
	}
	identity.SetMaxWorkFactor(18)
	decrypted, err := age.Decrypt(io.LimitReader(input, maxBackupBytes+(8<<20)), identity)
	if err != nil {
		return nil, core.Fail("BACKUP_INVALID")
	}
	if err = os.Mkdir(dataDir, 0700); err != nil {
		return nil, core.Fail("RESTORE_TARGET_EXISTS")
	}
	root, err := safeRoot(dataDir)
	if err != nil {
		return nil, err
	}
	if err = syncDirectory(filepath.Dir(root)); err != nil {
		return nil, err
	}
	marker, err := os.OpenFile(filepath.Join(root, ".restore-pending"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return nil, core.Fail("RESTORE_WRITE_FAILED")
	}
	if err = marker.Sync(); err != nil {
		marker.Close()
		return nil, core.Fail("RESTORE_WRITE_FAILED")
	}
	marker.Close()
	if err = syncDirectory(root); err != nil {
		return nil, err
	}
	s, err := acquire(root, false)
	if err != nil {
		return nil, err
	}
	success := false
	defer func() {
		if !success {
			s.Close()
		}
	}()
	archive := tar.NewReader(io.LimitReader(decrypted, maxBackupBytes+(1<<20)))
	seen := map[string]bool{}
	var manifest BackupManifest
	for {
		header, err := archive.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, core.Fail("BACKUP_INVALID")
		}
		if seen[header.Name] || header.Typeflag != tar.TypeReg || header.Size < 0 {
			return nil, core.Fail("BACKUP_INVALID")
		}
		seen[header.Name] = true
		var target string
		switch header.Name {
		case "manifest.json":
			if header.Size > 8192 {
				return nil, core.Fail("BACKUP_INVALID")
			}
			data, err := io.ReadAll(archive)
			if err != nil || json.Unmarshal(data, &manifest) != nil {
				return nil, core.Fail("BACKUP_INVALID")
			}
			continue
		case "master.key":
			if header.Size != 32 {
				return nil, core.Fail("BACKUP_INVALID")
			}
			if err = os.Mkdir(filepath.Join(root, "secrets"), 0700); err != nil {
				return nil, core.Fail("BACKUP_INVALID")
			}
			target = filepath.Join(root, "secrets/master.key")
		case "state.sqlite":
			if header.Size > maxBackupBytes {
				return nil, core.Fail("BACKUP_SIZE_LIMIT")
			}
			target = filepath.Join(root, "state.sqlite")
		default:
			return nil, core.Fail("BACKUP_INVALID")
		}
		f, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if err != nil {
			return nil, core.Fail("RESTORE_WRITE_FAILED")
		}
		n, writeErr := io.CopyN(f, archive, header.Size)
		syncErr := f.Sync()
		closeErr := f.Close()
		if writeErr != nil || syncErr != nil || closeErr != nil || n != header.Size {
			return nil, core.Fail("RESTORE_WRITE_FAILED")
		}
	}
	// 读到加密流结尾，以验证最后的认证块，不能只信 tar 的 EOF。
	if _, err = io.Copy(io.Discard, decrypted); err != nil {
		return nil, core.Fail("BACKUP_INVALID")
	}
	if len(seen) != 3 || manifest.Format != "noonmark-instance-backup/1" || manifest.Schema != schemaVersion {
		return nil, core.Fail("BACKUP_INVALID")
	}
	f, err := os.Open(filepath.Join(root, "state.sqlite"))
	if err != nil {
		return nil, core.Fail("BACKUP_INVALID")
	}
	hash := sha256.New()
	_, err = io.Copy(hash, f)
	f.Close()
	if err != nil || hex.EncodeToString(hash.Sum(nil)) != manifest.DatabaseSHA256 {
		return nil, core.Fail("BACKUP_INVALID")
	}
	if err = s.connect(ctx); err != nil {
		return nil, err
	}
	var version int
	if err = s.db.QueryRowContext(ctx, "PRAGMA user_version").Scan(&version); err != nil || version != schemaVersion {
		return nil, core.Fail("SCHEMA_UNSUPPORTED")
	}
	if err = s.Doctor(ctx); err != nil {
		return nil, err
	}
	if err = s.ValidateKey(); err != nil {
		return nil, err
	}
	if !s.OwnerInitialized(ctx) {
		return nil, core.Fail("OWNER_REQUIRED")
	}
	var instance, dataset string
	var seq int64
	if err = s.db.QueryRowContext(ctx, "SELECT instance_id,dataset_id,sequence FROM instance_state WHERE id=1").Scan(&instance, &dataset, &seq); err != nil || instance != manifest.InstanceID || dataset != manifest.DatasetID || seq != manifest.Sequence {
		return nil, core.Fail("BACKUP_INVALID")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, storageError(err)
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, "UPDATE instance_state SET instance_epoch=? WHERE id=1", uuid()); err != nil {
		return nil, storageError(err)
	}
	if _, err = tx.ExecContext(ctx, "DELETE FROM sessions"); err != nil {
		return nil, storageError(err)
	}
	if err = tx.Commit(); err != nil {
		return nil, storageError(err)
	}
	if err = syncDirectory(filepath.Join(root, "secrets")); err != nil {
		return nil, err
	}
	if err = os.Remove(filepath.Join(root, ".restore-pending")); err != nil {
		return nil, core.Fail("RESTORE_WRITE_FAILED")
	}
	if err = syncDirectory(root); err != nil {
		return nil, err
	}
	success = true
	return s, nil
}

func (s *Store) BackupFile(ctx context.Context, path, passphrase string) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return core.Fail("BACKUP_TARGET_EXISTS")
	}
	_, backupErr := s.Backup(ctx, file, passphrase)
	syncErr := file.Sync()
	closeErr := file.Close()
	if backupErr != nil {
		return backupErr
	}
	if syncErr != nil || closeErr != nil {
		return core.Fail("BACKUP_WRITE_FAILED")
	}
	return syncDirectory(filepath.Dir(path))
}

func BackupError(err error) string {
	if errors.Is(err, ErrPassword) {
		return "PASSWORD_INVALID"
	}
	return core.ErrorCode(err)
}
