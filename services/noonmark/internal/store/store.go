package store

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/mattn/go-sqlite3"
	"github.com/quboliu/noonmark/services/noonmark/internal/core"
)

type Store struct {
	db    *sql.DB
	root  string
	lock  *os.File
	mu    sync.Mutex
	now   func() time.Time
	newID func() string
}

func uuid() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("secure randomness unavailable")
	}
	b[6] = (b[6] & 15) | 64
	b[8] = (b[8] & 63) | 128
	s := hex.EncodeToString(b[:])
	return s[:8] + "-" + s[8:12] + "-" + s[12:16] + "-" + s[16:20] + "-" + s[20:]
}

func safeRoot(dataDir string) (string, error) {
	root, err := filepath.Abs(dataDir)
	if err != nil {
		return "", core.Fail("INVALID_DATA_DIRECTORY")
	}
	resolved, err := filepath.EvalSymlinks(root)
	if err != nil || resolved != root {
		return "", core.Fail("INVALID_DATA_DIRECTORY")
	}
	st, err := os.Lstat(root)
	if err != nil || !st.IsDir() || st.Mode()&os.ModeSymlink != 0 || st.Mode().Perm()&0077 != 0 {
		return "", core.Fail("INVALID_DATA_DIRECTORY")
	}
	if stat, ok := st.Sys().(*syscall.Stat_t); !ok || int(stat.Uid) != os.Geteuid() {
		return "", core.Fail("INVALID_DATA_DIRECTORY")
	}
	return root, nil
}

func acquire(dataDir string, exclusive bool) (*Store, error) {
	root, err := safeRoot(dataDir)
	if err != nil {
		return nil, err
	}
	flags := syscall.O_RDWR | syscall.O_CREAT | syscall.O_NOFOLLOW
	if exclusive {
		flags |= syscall.O_EXCL
	}
	fd, err := syscall.Open(filepath.Join(root, "instance.lock"), flags, 0600)
	if err != nil {
		return nil, core.Fail("INSTANCE_LOCK_FAILED")
	}
	lock := os.NewFile(uintptr(fd), "instance.lock")
	if err = syscall.Flock(fd, syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		return nil, core.Fail("INSTANCE_LOCKED")
	}
	return &Store{root: root, lock: lock, now: time.Now, newID: uuid}, nil
}

func (s *Store) connect(ctx context.Context) error {
	for _, suffix := range []string{"", "-wal", "-shm"} {
		st, err := os.Lstat(filepath.Join(s.root, "state.sqlite"+suffix))
		if errors.Is(err, os.ErrNotExist) && suffix != "" {
			continue
		}
		if err != nil || !st.Mode().IsRegular() {
			return core.Fail("INVALID_DATABASE_FILE")
		}
	}
	u := url.URL{Scheme: "file", Path: filepath.Join(s.root, "state.sqlite")}
	q := u.Query()
	q.Set("mode", "rw")
	q.Set("_journal_mode", "WAL")
	q.Set("_synchronous", "FULL")
	q.Set("_foreign_keys", "on")
	q.Set("_busy_timeout", "5000")
	q.Set("_txlock", "immediate")
	u.RawQuery = q.Encode()
	db, err := sql.Open("sqlite3", u.String())
	if err != nil {
		return storageError(err)
	}
	s.db = db
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	if err = db.PingContext(ctx); err != nil {
		return storageError(err)
	}
	var journal string
	var syncMode, fk int
	if err = db.QueryRowContext(ctx, "PRAGMA journal_mode").Scan(&journal); err != nil {
		return storageError(err)
	}
	if err = db.QueryRowContext(ctx, "PRAGMA synchronous").Scan(&syncMode); err != nil {
		return storageError(err)
	}
	if err = db.QueryRowContext(ctx, "PRAGMA foreign_keys").Scan(&fk); err != nil {
		return storageError(err)
	}
	if journal != "wal" || syncMode != 2 || fk != 1 {
		return core.Fail("STORAGE_CONFIGURATION")
	}
	return nil
}

// Init 只初始化空运行根，并独占创建锁文件；失败后保留状态，不接管既有实例。
func Init(ctx context.Context, dataDir, timezone string) (*Store, error) {
	return initAt(ctx, dataDir, timezone, time.Now())
}

// initAt 的注入仅供尚无领域事实的受控演示／测试初始化。
func initAt(ctx context.Context, dataDir, timezone string, reference time.Time) (*Store, error) {
	if _, err := time.LoadLocation(timezone); err != nil || timezone == "" || timezone == "Local" {
		return nil, core.Fail("INVALID_TIMEZONE")
	}
	if err := os.Mkdir(dataDir, 0700); err != nil && !errors.Is(err, os.ErrExist) {
		return nil, core.Fail("INVALID_DATA_DIRECTORY")
	}
	root, err := safeRoot(dataDir)
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) != 0 {
		return nil, core.Fail("DATA_DIRECTORY_EXISTS")
	}
	s, err := acquire(dataDir, true)
	if err != nil {
		return nil, err
	}
	success := false
	defer func() {
		if !success {
			s.Close()
		}
	}()
	f, err := os.OpenFile(filepath.Join(s.root, "state.sqlite"), os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return nil, core.Fail("DATABASE_EXISTS")
	}
	if err = f.Close(); err != nil {
		return nil, storageError(err)
	}
	if err = s.connect(ctx); err != nil {
		return nil, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, storageError(err)
	}
	defer tx.Rollback()
	if _, err = tx.ExecContext(ctx, schemaSQL); err != nil {
		return nil, storageError(err)
	}
	bits, err := core.NextMutation(reference, "")
	if err != nil {
		return nil, err
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO instance_state VALUES(1,?,?,?,?,?,0,?)", uuid(), uuid(), uuid(), uuid(), timezone, bits); err != nil {
		return nil, storageError(err)
	}
	if err = tx.Commit(); err != nil {
		return nil, storageError(err)
	}
	if err = syncDirectory(s.root); err != nil {
		return nil, err
	}
	if err = syncDirectory(filepath.Dir(s.root)); err != nil {
		return nil, err
	}
	success = true
	return s, nil
}
func Open(ctx context.Context, dataDir string) (*Store, error) {
	return openAt(ctx, dataDir, time.Now)
}

func openAt(ctx context.Context, dataDir string, now func() time.Time) (*Store, error) {
	s, err := acquire(dataDir, false)
	if err != nil {
		return nil, err
	}
	s.now = now
	success := false
	defer func() {
		if !success {
			s.Close()
		}
	}()
	if _, err = os.Lstat(filepath.Join(s.root, ".restore-pending")); !errors.Is(err, os.ErrNotExist) {
		return nil, core.Fail("RESTORE_INCOMPLETE")
	}
	if err = s.connect(ctx); err != nil {
		return nil, err
	}
	var version int
	if err = s.db.QueryRowContext(ctx, "PRAGMA user_version").Scan(&version); err != nil {
		return nil, storageError(err)
	}
	if version != schemaVersion {
		return nil, core.Fail("SCHEMA_UNSUPPORTED")
	}
	if err = s.Doctor(ctx); err != nil {
		return nil, err
	}
	success = true
	return s, nil
}
func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	var err error
	if s.db != nil {
		err = s.db.Close()
		s.db = nil
	}
	if s.lock != nil {
		unlockErr := syscall.Flock(int(s.lock.Fd()), syscall.LOCK_UN)
		closeErr := s.lock.Close()
		s.lock = nil
		if err == nil {
			err = unlockErr
		}
		if err == nil {
			err = closeErr
		}
	}
	return err
}
func syncDirectory(path string) error {
	d, err := os.Open(path)
	if err != nil {
		return storageError(err)
	}
	defer d.Close()
	return storageError(d.Sync())
}
func storageError(err error) error {
	if err == nil {
		return nil
	}
	var typed *core.Error
	if errors.As(err, &typed) {
		return err
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return core.Fail("REQUEST_CANCELLED")
	}
	var se sqlite3.Error
	if errors.As(err, &se) {
		switch se.Code {
		case sqlite3.ErrFull:
			return core.Fail("STORAGE_FULL")
		case sqlite3.ErrBusy, sqlite3.ErrLocked:
			return core.Fail("BUSY")
		case sqlite3.ErrConstraint:
			return core.Fail("INVARIANT_VIOLATION")
		}
	}
	return core.Fail("STORAGE_FAILURE")
}

func (s *Store) Snapshot(ctx context.Context) (core.Snapshot, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := s.settle(ctx); err != nil {
		return core.Snapshot{}, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.Snapshot{}, storageError(err)
	}
	defer tx.Rollback()
	out, err := s.read(ctx, tx)
	if err != nil {
		return out, err
	}
	if err = tx.Commit(); err != nil {
		return out, storageError(err)
	}
	return core.Project(out), nil
}
func (s *Store) settle(ctx context.Context) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return storageError(err)
	}
	defer tx.Rollback()
	if err = s.validateSessionTx(ctx, tx); err != nil {
		return err
	}
	before, err := s.read(ctx, tx)
	if err != nil {
		return err
	}
	after, changed, err := core.Settle(before, s.now(), s.newID)
	if err != nil {
		return err
	}
	if !changed {
		return nil
	}
	if err = s.persist(ctx, tx, before, after); err != nil {
		return err
	}
	seq, err := nextSequence(before.Sequence)
	if err != nil {
		return err
	}
	if _, err = tx.ExecContext(ctx, "UPDATE instance_state SET sequence=?,frontier_bits=? WHERE id=1", seq, after.FrontierBits); err != nil {
		return storageError(err)
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO change_batches VALUES(?,?,?,?,?)", before.DatasetID, seq, "", "day_settlement", after.FrontierBits); err != nil {
		return storageError(err)
	}
	return storageError(tx.Commit())
}
func nextSequence(s string) (int64, error) {
	seq, err := strconv.ParseInt(s, 10, 64)
	if err != nil || seq == int64(^uint64(0)>>1) {
		return 0, core.Fail("SEQUENCE_EXHAUSTED")
	}
	return seq + 1, nil
}

func (s *Store) Execute(ctx context.Context, c core.Command) (core.Receipt, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var empty core.Receipt
	if c.SchemaVersion != schemaVersion {
		return empty, core.Fail("SCHEMA_UNSUPPORTED")
	}
	if !core.ValidID(c.CommandID) || !core.ValidID(c.InstanceID) || !core.ValidID(c.InstanceEpoch) || !core.ValidID(c.DatasetID) {
		return empty, core.Fail("INVALID_INPUT")
	}
	if err := s.settle(ctx); err != nil {
		return empty, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return empty, storageError(err)
	}
	defer tx.Rollback()
	if err = s.validateSessionTx(ctx, tx); err != nil {
		return empty, err
	}
	before, err := s.read(ctx, tx)
	if err != nil {
		return empty, err
	}
	if c.InstanceID != before.InstanceID || c.InstanceEpoch != before.InstanceEpoch {
		return empty, core.Fail("INSTANCE_CHANGED")
	}
	if c.DatasetID != before.DatasetID {
		return empty, core.Fail("DATASET_INACTIVE")
	}
	body, err := json.Marshal(c)
	if err != nil {
		return empty, core.Fail("INVALID_INPUT")
	}
	digest := sha256.Sum256(body)
	hash := hex.EncodeToString(digest[:])
	receipt, priorHash, err := readReceipt(ctx, tx, before.DatasetID, c.CommandID)
	if err == nil {
		if priorHash != hash {
			return empty, core.Fail("IDEMPOTENCY_MISMATCH")
		}
		return receipt, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return empty, storageError(err)
	}
	after, id, err := core.Apply(before, c, s.now(), s.newID)
	if err != nil {
		return empty, err
	}
	if err = s.persist(ctx, tx, before, after); err != nil {
		return empty, err
	}
	seq, err := nextSequence(before.Sequence)
	if err != nil {
		return empty, err
	}
	receipt = core.Receipt{CommandID: c.CommandID, Status: "committed", Sequence: strconv.FormatInt(seq, 10), EntityID: id, MutationBits: after.FrontierBits}
	if _, err = tx.ExecContext(ctx, "INSERT INTO command_receipts VALUES(?,?,?,?,?,?)", before.DatasetID, c.CommandID, hash, seq, id, after.FrontierBits); err != nil {
		return empty, storageError(err)
	}
	if _, err = tx.ExecContext(ctx, "INSERT INTO change_batches VALUES(?,?,?,?,?)", before.DatasetID, seq, c.CommandID, c.Type, after.FrontierBits); err != nil {
		return empty, storageError(err)
	}
	if _, err = tx.ExecContext(ctx, "UPDATE instance_state SET sequence=?,frontier_bits=? WHERE id=1", seq, after.FrontierBits); err != nil {
		return empty, storageError(err)
	}
	if err = tx.Commit(); err != nil {
		return empty, storageError(err)
	}
	return receipt, nil
}
func readReceipt(ctx context.Context, tx *sql.Tx, dataset, id string) (core.Receipt, string, error) {
	r := core.Receipt{CommandID: id, Status: "committed"}
	var seq int64
	var hash string
	err := tx.QueryRowContext(ctx, "SELECT request_hash,sequence,entity_id,mutation_bits FROM command_receipts WHERE dataset_id=? AND command_id=?", dataset, id).Scan(&hash, &seq, &r.EntityID, &r.MutationBits)
	r.Sequence = strconv.FormatInt(seq, 10)
	return r, hash, err
}
func (s *Store) Receipt(ctx context.Context, id string) (core.Receipt, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !core.ValidID(id) {
		return core.Receipt{}, core.Fail("INVALID_INPUT")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return core.Receipt{}, storageError(err)
	}
	defer tx.Rollback()
	if err = s.validateSessionTx(ctx, tx); err != nil {
		return core.Receipt{}, err
	}
	var dataset string
	if err = tx.QueryRowContext(ctx, "SELECT dataset_id FROM instance_state WHERE id=1").Scan(&dataset); err != nil {
		return core.Receipt{}, storageError(err)
	}
	r, _, err := readReceipt(ctx, tx, dataset, id)
	if errors.Is(err, sql.ErrNoRows) {
		return r, core.Fail("NOT_FOUND")
	}
	return r, storageError(err)
}
func (s *Store) Doctor(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return storageError(err)
	}
	defer tx.Rollback()
	var result string
	if err = tx.QueryRowContext(ctx, "PRAGMA quick_check").Scan(&result); err != nil || result != "ok" {
		return core.Fail("INTEGRITY_FAILURE")
	}
	rows, err := tx.QueryContext(ctx, "PRAGMA foreign_key_check")
	if err != nil {
		return storageError(err)
	}
	bad := rows.Next()
	rowErr := rows.Err()
	rows.Close()
	if bad || rowErr != nil {
		return core.Fail("INTEGRITY_FAILURE")
	}
	snapshot, err := s.read(ctx, tx)
	if err != nil {
		return err
	}
	return core.Validate(snapshot)
}

// String 不暴露运行根、用户正文或身份。
func (s *Store) String() string { return fmt.Sprintf("NoonmarkStore(schema=%d)", schemaVersion) }
