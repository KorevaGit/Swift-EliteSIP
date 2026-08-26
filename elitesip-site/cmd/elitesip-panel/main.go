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
	"github.com/koreva/elitesip-site/internal/preset"
	"github.com/koreva/elitesip-site/internal/publish"
	"github.com/koreva/elitesip-site/internal/sand"
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
	case "preset-import":
		err = importPreset(os.Args[2:])
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
  elitesip-panel preset-import <имя> <файл.json>
                                    завести предустановку из управляемых полей

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

	sandDB, err := sand.Open(cfg.SandDBPath)
	if err != nil {
		return err
	}
	defer sandDB.Close()

	signingKey, err := config.LoadSigningKey(cfg.SigningKeyFile)
	if err != nil {
		return err
	}
	secret, err := config.LoadSecret(cfg.SecretFile)
	if err != nil {
		return err
	}

	var sink panel.Store
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

	// Помашинные объекты подписываются тем же ключом, что и файл
	// предустановок: два ключа подписи означали бы два публичных ключа в
	// приложении и второй способ ошибиться, какой из них чей.
	machines := &panel.MachineWriter{Publisher: sink, SigningKey: signingKey}

	site, err := web.New(db, sandDB,
		&panel.Issuer{DB: db, Publisher: sink, Machines: machines, Secret: secret},
		&panel.BundlePublisher{DB: db, Publisher: sink, SigningKey: signingKey},
		&panel.MarkCollector{DB: db, Reader: sink, Machines: machines},
		&panel.Revoker{DB: db, Machines: machines, Deleter: sink},
		&panel.AccessPublisher{DB: db, Machines: machines},
		secret,
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

	// Журнал чистится там же и по той же причине: панель перезапускают чаще
	// раза в три месяца, а рутина, которую уносит уборка, за сутки не
	// накапливается. Удаления сотрудников она не трогает — на них держится
	// ответ на «кто сидел на этом добавочном».
	if removed, err := db.PurgeAudit(context.Background(), time.Now()); err != nil {
		fmt.Fprintf(os.Stderr, "не удалось почистить журнал: %v\n", err)
	} else if removed > 0 {
		fmt.Fprintf(os.Stderr, "из журнала убрано строк старше трёх месяцев: %d\n", removed)
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

	// За отметками панель ходит сама, а не только по нажатию: «ключ забрали»
	// должно появляться без того, чтобы кто-то за этим следил.
	//
	// Отказ пишется в поток ошибок и не роняет панель: бакет недоступен —
	// значит, сведения о машинах устареют, а всё остальное продолжает работать.
	// Это ровно то же требование, что предъявлено приложению в M7c.
	sweeper := &panel.Sweeper{DB: db, Store: sink}

	collect, stopCollecting := context.WithCancel(context.Background())
	defer stopCollecting()

	// Outbox пробуем разобрать сразу при запуске: если прошлый процесс умер
	// между двумя базами, журнал восстановится до первого действия человека.
	if _, err := sandDB.DeliverAudit(collect, db, 0); err != nil {
		fmt.Fprintf(os.Stderr, "не удалось доставить журнал песочницы: %v\n", err)
	}
	go func() {
		ticker := time.NewTicker(sand.AuditDeliveryInterval)
		defer ticker.Stop()
		for {
			select {
			case <-collect.Done():
				return
			case <-ticker.C:
				if _, err := sandDB.DeliverAudit(collect, db, 0); err != nil {
					fmt.Fprintf(os.Stderr, "не удалось доставить журнал песочницы: %v\n", err)
				}
			}
		}
	}()

	go func() {
		ticker := time.NewTicker(panel.CollectInterval)
		defer ticker.Stop()
		for {
			select {
			case <-collect.Done():
				return
			case <-ticker.C:
				if _, err := site.Marks.Collect(collect); err != nil {
					fmt.Fprintf(os.Stderr, "не удалось сходить за отметками: %v\n", err)
				}
				// Уборка идёт следом за разбором отметок, а не своим
				// расписанием: она уносит забранные пакеты, а «забранные» —
				// это ровно то, что панель узнаёт шагом выше. Своим таймером
				// она половину заходов работала бы по вчерашним сведениям.
				if _, err := sweeper.Sweep(collect); err != nil {
					fmt.Fprintf(os.Stderr, "не удалось убрать в бакете: %v\n", err)
				}
			}
		}
	}()

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

// importPreset заводит предустановку из готового набора управляемых полей.
//
// Существует ради переноса того, что уже настроено на живой машине. Раньше это
// делалось снимком настроек в самом приложении, но снимки убраны 25 августа
// 2026: они были конторскими настройками в локальном файле, применяемом мимо
// панели. Дорога «настроили машину — перенесли в панель» при этом нужна, и вот
// она: поля вынимаются из `settings.json` рабочего места и кладутся сюда.
//
// Идёт тем же путём, что и правка через интерфейс: разбор, проверка, ревизия.
// Класть в базу запросом мимо них было бы быстрее и означало бы предустановку,
// которую панель считает годной, а машина не понимает.
func importPreset(args []string) error {
	if len(args) != 2 || strings.TrimSpace(args[0]) == "" {
		return errors.New("нужно имя и файл: elitesip-panel preset-import <имя> <файл.json>")
	}
	name := strings.TrimSpace(args[0])

	raw, err := os.ReadFile(args[1])
	if err != nil {
		return fmt.Errorf("прочитать %s: %w", args[1], err)
	}

	fields, err := preset.Parse(raw)
	if err != nil {
		return err
	}
	if problems := fields.Validate(); len(problems) > 0 {
		for _, p := range problems {
			fmt.Fprintln(os.Stderr, "  —", p)
		}
		return fmt.Errorf("предустановка не годится: замечаний %d", len(problems))
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

	ctx := context.Background()

	// Одноимённая не заводится второй раз, а получает новую ревизию: имя —
	// то, по чему человек её узнаёт, и два «Менеджера» в списке означали бы
	// вопрос «который из них», на который никто не ответит.
	existing, err := db.ListPresets(ctx, true)
	if err != nil {
		return err
	}
	var id int64
	for _, p := range existing {
		if p.Name == name {
			id = p.ID
			break
		}
	}
	if id == 0 {
		created, err := db.CreatePreset(ctx, nil, name)
		if err != nil {
			return err
		}
		id = created.ID
		fmt.Fprintf(os.Stderr, "заведена предустановка %q\n", name)
	} else {
		fmt.Fprintf(os.Stderr, "предустановка %q уже есть — добавляю ревизию\n", name)
	}

	// Поля пересобираются из разобранного, а не берутся файлом как есть:
	// так в базу ложится ровно то, что панель поняла, без чужих полей рядом.
	canonical, err := fields.Canonical()
	if err != nil {
		return err
	}

	revision, err := db.SaveRevision(ctx, nil, id, preset.SchemaVersion, canonical, "перенос с рабочей машины")
	if err != nil {
		return err
	}

	fmt.Fprintf(os.Stderr, "ревизия %d сохранена\n", revision.Revision)
	fmt.Fprintln(os.Stderr, "не забудьте задать административный пароль и выложить файл предустановок")
	return nil
}
