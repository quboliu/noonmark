package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/quboliu/noonmark/services/noonmark/internal/store"
)

func withInput(t *testing.T, input string, action func() error) error {
	t.Helper()
	file, err := os.CreateTemp(t.TempDir(), "stdin-")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if _, err := file.WriteString(input); err != nil {
		t.Fatal(err)
	}
	if _, err := file.Seek(0, 0); err != nil {
		t.Fatal(err)
	}
	original := os.Stdin
	os.Stdin = file
	defer func() { os.Stdin = original }()
	return action()
}

func TestInitInvalidPasswordCannotPoisonInstance(t *testing.T) {
	for name, password := range map[string]string{"short": "short", "multibyte short": "一二三四", "oversized": strings.Repeat("x", 1025)} {
		t.Run(name, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "instance")
			err := withInput(t, password+"\n", func() error { return run([]string{"init", "--data-dir", root, "--password-stdin"}) })
			if !errors.Is(err, store.ErrPassword) {
				t.Fatalf("invalid password error = %v", err)
			}
			if _, err := os.Stat(root); !errors.Is(err, os.ErrNotExist) {
				t.Fatal("invalid password created instance state")
			}
			err = withInput(t, "valid-test-passphrase-734\n", func() error {
				return run([]string{"init", "--data-dir", root, "--timezone", "Asia/Singapore", "--password-stdin"})
			})
			if err != nil {
				t.Fatalf("retry after invalid input failed: %v", err)
			}
			database, err := store.Open(context.Background(), root)
			if err != nil {
				t.Fatal(err)
			}
			defer database.Close()
			if !database.OwnerInitialized(context.Background()) {
				t.Fatal("owner not initialized")
			}
			if err := database.ValidateKey(); err != nil {
				t.Fatal("instance key was not initialized")
			}
		})
	}
}

func TestInitRejectedPasswordLeavesMountedEmptyDirectoryEmpty(t *testing.T) {
	root := t.TempDir()
	err := withInput(t, "short\n", func() error { return run([]string{"init", "--data-dir", root, "--password-stdin"}) })
	if !errors.Is(err, store.ErrPassword) {
		t.Fatal(err)
	}
	files, err := os.ReadDir(root)
	if err != nil || len(files) != 0 {
		t.Fatal("invalid password modified mounted empty data directory")
	}
}
