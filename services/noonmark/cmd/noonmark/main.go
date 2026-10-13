package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
	_ "time/tzdata"

	"github.com/quboliu/noonmark/services/noonmark/internal/core"
	"github.com/quboliu/noonmark/services/noonmark/internal/httpapi"
	"github.com/quboliu/noonmark/services/noonmark/internal/store"
	"golang.org/x/term"
)

var version = "0.1.0-dev"

func main() {
	if err := run(os.Args[1:]); err != nil {
		code := core.ErrorCode(err)
		if errors.Is(err, store.ErrPassword) {
			code = "PASSWORD_INVALID"
		}
		if code == "INTERNAL" {
			var typed *cliError
			if errors.As(err, &typed) {
				code = typed.code
			}
		}
		// CLI 只输出 typed code，不输出配置路径、凭证或原始底层错误。
		fmt.Fprintln(os.Stderr, "noonmark:", code)
		os.Exit(1)
	}
}

type cliError struct{ code string }

func (e *cliError) Error() string { return e.code }
func fail(code string) error      { return &cliError{code} }
func env(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}

func run(args []string) error {
	if len(args) > 0 && (args[0] == "help" || args[0] == "--help" || args[0] == "-h") {
		fmt.Println("Noonmark 个人实例\n命令：init、serve、doctor、backup、restore、reset-password、healthcheck、demo、version\n使用 noonmark <command> --help 查看参数；密码只从终端或 --password-stdin 读取。")
		return nil
	}
	if len(args) == 0 {
		return fail("COMMAND_REQUIRED")
	}
	if args[0] == "version" {
		fmt.Println(version)
		return nil
	}
	flags := flag.NewFlagSet(args[0], flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	dataDir := flags.String("data-dir", env("NOONMARK_DATA_DIR", "/data"), "实例数据目录")
	stdin := flags.Bool("password-stdin", false, "从标准输入读取密码，不回显")
	zone := flags.String("timezone", env("NOONMARK_OWNER_TIMEZONE", "Asia/Singapore"), "owner 的 IANA 时区")
	listen := flags.String("listen", env("NOONMARK_LISTEN_ADDR", "127.0.0.1:8080"), "监听地址")
	origin := flags.String("public-origin", env("NOONMARK_PUBLIC_ORIGIN", "http://127.0.0.1:8080"), "浏览器使用的实例 origin")
	webDir := flags.String("web-dir", env("NOONMARK_WEB_DIR", "/opt/noonmark/web"), "同版本静态资源目录")
	proxy := flags.String("trusted-proxy", env("NOONMARK_TRUSTED_PROXY", ""), "受信反向代理 CIDR")
	cert := flags.String("tls-cert", env("NOONMARK_TLS_CERT", ""), "TLS 证书文件")
	key := flags.String("tls-key", env("NOONMARK_TLS_KEY", ""), "TLS 私钥文件")
	output := flags.String("output", "", "备份目标，必须不存在")
	input := flags.String("input", "", "加密备份源")
	healthURL := flags.String("url", "http://127.0.0.1:8080", "健康检查 origin")
	if err := flags.Parse(args[1:]); errors.Is(err, flag.ErrHelp) {
		flags.SetOutput(os.Stdout)
		flags.PrintDefaults()
		return nil
	} else if err != nil || flags.NArg() != 0 {
		return fail("ARGUMENT_INVALID")
	}
	ctx := context.Background()
	switch args[0] {
	case "demo":
		password, err := readPassword(*stdin, "设置演示实例密码（至少 12 个字符）：")
		if err != nil {
			return err
		}
		report, err := store.CreateDemo(ctx, *dataDir, *zone, password)
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(report)
	case "init":
		password, err := readPassword(*stdin, "设置实例密码（至少 12 个字符）：")
		if err != nil {
			return err
		}
		if err = store.ValidatePassword(password); err != nil {
			return err
		}
		database, err := store.Init(ctx, *dataDir, *zone)
		if err != nil {
			return err
		}
		defer database.Close()
		if err = database.InitializeOwner(ctx, password); err != nil {
			return err
		}
		if err = database.InitializeKey(); err != nil {
			return err
		}
		return status("initialized")
	case "serve":
		database, err := store.Open(ctx, *dataDir)
		if err != nil {
			return err
		}
		defer database.Close()
		if err = database.ValidateKey(); err != nil {
			return err
		}
		config := httpapi.Config{PublicOrigin: *origin, WebDir: *webDir, Version: version}
		if *proxy != "" {
			network, err := httpapi.ParseProxy(*proxy)
			if err != nil {
				return fail("PROXY_INVALID")
			}
			config.TrustedProxies = []*net.IPNet{network}
		}
		handler, err := httpapi.New(database, config)
		if err != nil {
			return fail("SERVER_CONFIG_INVALID")
		}
		if (*cert == "") != (*key == "") {
			return fail("TLS_CONFIG_INVALID")
		}
		if strings.HasPrefix(*origin, "https://") && *cert == "" && *proxy == "" {
			return fail("TLS_REQUIRED")
		}
		base, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
		defer stop()
		maintenanceDone := make(chan struct{})
		go func() {
			defer close(maintenanceDone)
			ticker := time.NewTicker(30 * time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-base.Done():
					return
				case <-ticker.C:
					_, _ = database.Snapshot(base)
				}
			}
		}()
		defer func() { stop(); <-maintenanceDone }()
		server := &http.Server{Addr: *listen, Handler: handler, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 16 << 10, ErrorLog: log.New(io.Discard, "", 0), BaseContext: func(net.Listener) context.Context { return base }}
		listener, err := net.Listen("tcp", *listen)
		if err != nil {
			return fail("LISTEN_FAILED")
		}
		errorsChannel := make(chan error, 1)
		go func() {
			if *cert != "" {
				errorsChannel <- server.ServeTLS(listener, *cert, *key)
			} else {
				errorsChannel <- server.Serve(listener)
			}
		}()
		_ = status("serving")
		select {
		case err = <-errorsChannel:
			if !errors.Is(err, http.ErrServerClosed) {
				return fail("SERVER_FAILED")
			}
		case <-base.Done():
			shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			if err = server.Shutdown(shutdown); err != nil {
				_ = server.Close()
				return fail("SHUTDOWN_FAILED")
			}
		}
		return nil
	case "doctor":
		database, err := store.Open(ctx, *dataDir)
		if err != nil {
			return err
		}
		defer database.Close()
		if !database.OwnerInitialized(ctx) {
			return fail("OWNER_REQUIRED")
		}
		if err = database.ValidateKey(); err != nil {
			return err
		}
		if err = database.Doctor(ctx); err != nil {
			return err
		}
		return status("healthy")
	case "reset-password":
		password, err := readPassword(*stdin, "新的实例密码（至少 12 个字符）：")
		if err != nil {
			return err
		}
		database, err := store.Open(ctx, *dataDir)
		if err != nil {
			return err
		}
		defer database.Close()
		if err = database.ResetPassword(ctx, password); err != nil {
			return err
		}
		return status("password_reset")
	case "backup":
		if *output == "" {
			return fail("OUTPUT_REQUIRED")
		}
		password, err := readPassword(*stdin, "备份加密口令（至少 12 个字符）：")
		if err != nil {
			return err
		}
		database, err := store.Open(ctx, *dataDir)
		if err != nil {
			return err
		}
		defer database.Close()
		if err = database.BackupFile(ctx, *output, password); err != nil {
			return err
		}
		return status("backup_complete")
	case "restore":
		if *input == "" {
			return fail("INPUT_REQUIRED")
		}
		password, err := readPassword(*stdin, "备份解密口令：")
		if err != nil {
			return err
		}
		file, err := os.Open(*input)
		if err != nil {
			return fail("BACKUP_UNAVAILABLE")
		}
		defer file.Close()
		database, err := store.Restore(ctx, *dataDir, file, password)
		if err != nil {
			return err
		}
		defer database.Close()
		return status("restored")
	case "healthcheck":
		check, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()
		request, err := http.NewRequestWithContext(check, http.MethodGet, strings.TrimSuffix(*healthURL, "/")+"/healthz", nil)
		if err != nil {
			return fail("HEALTHCHECK_FAILED")
		}
		response, err := (&http.Client{Timeout: 3 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("redirect rejected") }}).Do(request)
		if err != nil {
			return fail("HEALTHCHECK_FAILED")
		}
		defer response.Body.Close()
		if response.StatusCode != 200 {
			return fail("HEALTHCHECK_FAILED")
		}
		return nil
	default:
		return fail("UNKNOWN_COMMAND")
	}
}

func status(value string) error {
	return json.NewEncoder(os.Stdout).Encode(map[string]string{"status": value})
}

func readPassword(stdin bool, prompt string) (string, error) {
	if stdin {
		reader := bufio.NewReader(io.LimitReader(os.Stdin, 1026))
		line, err := reader.ReadString('\n')
		if err != nil && err != io.EOF {
			return "", fail("PASSWORD_READ_FAILED")
		}
		line = strings.TrimSuffix(strings.TrimSuffix(line, "\n"), "\r")
		if len(line) > 1024 {
			return "", store.ErrPassword
		}
		return line, nil
	}
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return "", fail("PASSWORD_STDIN_FLAG_REQUIRED")
	}
	fmt.Fprint(os.Stderr, prompt)
	data, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Fprintln(os.Stderr)
	if err != nil {
		return "", fail("PASSWORD_READ_FAILED")
	}
	password := string(data)
	clear(data)
	return password, nil
}
