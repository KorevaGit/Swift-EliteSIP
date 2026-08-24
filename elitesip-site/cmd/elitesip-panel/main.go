// Команда elitesip-panel — панель EliteSIP.
//
// Один бинарник на всё: сервер, заведение администраторов и выпуск ключей
// подписи. Отдельные утилиты рядом означали бы, что на сервер надо принести
// несколько файлов и не перепутать их версии.
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/koreva/elitesip-site/internal/config"
	"github.com/koreva/elitesip-site/internal/panel"
	"github.com/koreva/elitesip-site/internal/publish"
	"github.com/koreva/elitesip-site/internal/storage"
	"github.com/koreva/elitesip-site/internal/web"
)

func main() {
	command := "serve"
	if len(os.Args) > 1 {
		command = os.Args[1]
	}

	var err error
	switch command {
	case "serve":
		err = serve()
	case "keygen":
		err = keygen()
	case "admin":
		err = addAdmin(os.Args[2:])
	case "help", "-h", "--help":
		usage()
	default:
		usage()
		err = fmt.Errorf("неизвестная команда %q", command)
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "elitesip-panel: %v\n", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `Панель EliteSIP.

  elitesip-panel serve              поднять панель (по умолчанию)
  elitesip-panel keygen             выпустить ключ подписи и секрет сервера
  elitesip-panel admin <имя>        завести администратора, пароль — со stdin

Настройки берутся из окружения; секреты — путями к файлам, а не значениями.
`)
}

func serve() error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}

	db, err := storage.Open(cfg.DBPath)
	if err != nil {
		return err
	}
	defer db.Close()

	signingKey, err := config.LoadSigningKey(cfg.SigningKeyFile)
	if err != nil {
		return err
	}
	secret, err := config.LoadSecret(cfg.SecretFile)
	if err != nil {
		return err
	}

	var sink panel.Publisher
	if cfg.PublishDir != "" {
		sink = publish.Dir{Root: cfg.PublishDir}
	} else {
		sink = &publish.R2{
			Endpoint:        cfg.R2Endpoint,
			Bucket:          cfg.R2Bucket,
			AccessKeyID:     cfg.R2AccessKey,
			SecretAccessKey: cfg.R2Secret,
		}
	}

	site, err := web.New(db,
		&panel.Issuer{DB: db, Publisher: sink, Secret: secret},
		&panel.BundlePublisher{DB: db, Publisher: sink, SigningKey: signingKey},
	)
	if err != nil {
		return err
	}

	count, err := db.AdminCount(context.Background())
	if err != nil {
		return err
	}
	if count == 0 {
		fmt.Fprintln(os.Stderr, "администраторов нет: первый заводится на странице /setup")
	}

	// Истёкшие сеансы убираются при запуске, а не по расписанию: панель
	// перезапускают чаще, чем накапливается что-то, за чем стоило бы следить
	// отдельным таймером.
	if err := db.PurgeExpiredSessions(context.Background()); err != nil {
		fmt.Fprintf(os.Stderr, "не удалось убрать истёкшие сеансы: %v\n", err)
	}

	server := &http.Server{
		Addr:              cfg.Listen,
		Handler:           site.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	// Останов по сигналу, а не по обрыву: докер шлёт SIGTERM и ждёт, и панель
	// должна успеть дописать то, что начала, — иначе перезапуск ради обновления
	// однажды придётся на середину выкладки.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	errs := make(chan error, 1)
	go func() {
		fmt.Fprintf(os.Stderr, "панель слушает %s\n", cfg.Listen)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errs <- err
		}
	}()

	select {
	case err := <-errs:
		return err
	case <-stop:
		ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		return server.Shutdown(ctx)
	}
}

// keygen выпускает оба секрета сервера.
//
// Печатает, а не записывает файлы сам: куда их класть, решает тот, кто ставит
// панель, а записанный не туда секрет с правильными правами хуже ненаписанного
// — его забудут убрать.
func keygen() error {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return fmt.Errorf("выпустить ключ подписи: %w", err)
	}

	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return fmt.Errorf("выпустить секрет сервера: %w", err)
	}

	fmt.Printf(`Ключ подписи линии предустановок.

Приватный — в файл ELITESIP_SIGNING_KEY_FILE, правами 600:

%s

Открытый — в Info.plist приложения. Его же придётся вписать в клиент до
первой выкладки: сменить ключ у уже настроенных машин нельзя, они перестанут
принимать файл.

%s

Секрет сервера — в файл ELITESIP_SECRET_FILE, правами 600. По нему считаются
отпечатки выданных ключей; потеря секрета означает, что найти активацию по
присланному ключу больше нельзя, но сами машины это не затрагивает.

%s
`,
		base64.StdEncoding.EncodeToString(priv.Seed()),
		base64.StdEncoding.EncodeToString(pub),
		base64.StdEncoding.EncodeToString(secret))
	return nil
}

// addAdmin заводит администратора. Пароль читается со stdin, а не из аргумента:
// аргумент попадает в историю оболочки и в список процессов.
func addAdmin(args []string) error {
	if len(args) != 1 || strings.TrimSpace(args[0]) == "" {
		return errors.New("нужно имя: elitesip-panel admin <имя>")
	}
	login := strings.TrimSpace(args[0])

	fmt.Fprint(os.Stderr, "пароль: ")
	var password string
	if _, err := fmt.Fscanln(os.Stdin, &password); err != nil {
		return fmt.Errorf("прочитать пароль: %w", err)
	}

	hash, err := panel.HashPassword(password)
	if err != nil {
		return err
	}

	cfg, err := config.Load()
	if err != nil {
		return err
	}
	db, err := storage.Open(cfg.DBPath)
	if err != nil {
		return err
	}
	defer db.Close()

	admin, err := db.CreateAdmin(context.Background(), nil, login, hash)
	if err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "заведён администратор %s (%d)\n", admin.Login, admin.ID)
	return nil
}
