// Package web — интерфейс панели.
//
// Серверный HTML без сборки фронта: шаблоны и один файл оформления вшиты в
// бинарник. Панель ставят на сервер, куда не ходят месяцами, и второй способ
// собрать её означал бы второй способ её сломать.
package web

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"html/template"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/koreva/elitesip-site/internal/model"
	"github.com/koreva/elitesip-site/internal/panel"
	"github.com/koreva/elitesip-site/internal/sand"
	"github.com/koreva/elitesip-site/internal/storage"
)

//go:embed templates/*.html
var templateFS embed.FS

//go:embed static/*
var staticFS embed.FS

const sessionCookie = "elitesip_session"

// Server — панель целиком.
type Server struct {
	DB        *storage.DB
	Sand      *sand.DB
	Issuer    *panel.Issuer
	Publisher *panel.BundlePublisher
	Marks     *panel.MarkCollector

	// Revoker отзывает доступ: отметка в базе, подписанный отзыв в бакете и
	// обрубленный ключ канала — три шага в одном месте, чтобы не делать их по
	// отдельности из разных экранов.
	Revoker *panel.Revoker

	// Access разносит административный пароль по машинам предустановки.
	Access *panel.AccessPublisher

	// CSRFSecret подписывает токены форм — тот же секрет сервера, что и у
	// отпечатков ключей в internal/panel, второго файла под него не заводим.
	CSRFSecret []byte

	templates map[string]*template.Template
	flashes   flashStore
}

// New собирает панель и разбирает шаблоны.
//
// Шаблоны разбираются при запуске, а не при первом показе: ошибка в шаблоне
// должна ронять запуск, а не тот единственный экран, который откроют в
// неудачный момент.
func New(db *storage.DB, sandDB *sand.DB, issuer *panel.Issuer, publisher *panel.BundlePublisher,
	marks *panel.MarkCollector, revoker *panel.Revoker,
	access *panel.AccessPublisher, csrfSecret []byte) (*Server, error) {
	s := &Server{DB: db, Sand: sandDB, Issuer: issuer, Publisher: publisher, Marks: marks,
		Revoker: revoker, Access: access, CSRFSecret: csrfSecret}
	if err := s.parseTemplates(); err != nil {
		return nil, err
	}
	return s, nil
}

var pages = []string{
	"login", "setup", "overview", "keys", "stub", "employees", "employee",
	"presets", "preset", "preset_edit", "audit", "settings",
	"sandbox", "sandbox_archive", "sandbox_new", "sandbox_template", "sandbox_detail",
	"sandbox_employee",
}

func (s *Server) parseTemplates() error {
	s.templates = make(map[string]*template.Template, len(pages))

	for _, name := range pages {
		t, err := template.New("base.html").Funcs(templateFuncs).
			ParseFS(templateFS, "templates/base.html", "templates/"+name+".html")
		if err != nil {
			return fmt.Errorf("разобрать шаблон %s: %w", name, err)
		}
		s.templates[name] = t
	}
	return nil
}

// Handler собирает маршруты.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()

	mux.Handle("GET /static/", http.FileServerFS(staticFS))
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		fmt.Fprintln(w, "ok")
	})

	mux.HandleFunc("GET /login", s.showLogin)
	mux.HandleFunc("POST /login", s.doLogin)
	mux.HandleFunc("POST /logout", s.doLogout)
	mux.HandleFunc("GET /setup", s.showSetup)
	mux.HandleFunc("POST /setup", s.doSetup)

	mux.Handle("GET /{$}", s.guard(s.redirectHome))
	mux.Handle("GET /overview", s.guard(s.showOverview))
	mux.Handle("POST /marks/pull", s.guard(s.pullMarks))
	mux.Handle("GET /keys", s.guard(s.showKeys))
	mux.Handle("GET /pbx", s.guard(s.showPBX))

	mux.Handle("GET /sandbox", s.guard(s.showSandboxes))
	mux.Handle("GET /sandbox/archive", s.guard(s.showSandboxArchive))
	mux.Handle("GET /sandbox/template", s.guard(s.showSandboxTemplate))
	mux.Handle("GET /sandbox/new", s.guard(s.newSandbox))
	// Форма несёт файл холодной базы, поэтому тело ограничивается и разбирается
	// до проверки токена: иначе слишком большой файл сказал бы «форма устарела».
	mux.Handle("POST /sandbox", s.limitUpload(maxDealsUpload, s.guard(s.createSandbox)))
	mux.Handle("GET /sandbox/{id}", s.guard(s.showSandboxDetail))
	mux.Handle("POST /sandbox/{id}/mark", s.guard(s.markSandboxTask))
	mux.Handle("POST /sandbox/{id}/employees", s.guard(s.addSandboxEmployee))
	mux.Handle("POST /sandbox/{id}/comments", s.guard(s.addSandboxComment))
	mux.Handle("POST /sandbox/{id}/close", s.guard(s.onlyAdmin(s.closeSandbox)))
	mux.Handle("GET /sandbox/{id}/employee/{eid}", s.guard(s.showSandEmployee))
	mux.Handle("POST /sandbox/{id}/employee/{eid}/mark", s.guard(s.markSandEmployee))
	mux.Handle("POST /sandbox/{id}/employee/{eid}/save", s.guard(s.saveSandEmployee))
	mux.Handle("POST /sandbox/{id}/employee/{eid}/extension", s.guard(s.assignSandExtension))
	mux.Handle("POST /sandbox/{id}/employee/{eid}/outcome", s.guard(s.outcomeSandEmployee))
	mux.Handle("POST /sandbox/{id}/employee/{eid}/deals", s.guard(s.downloadSandDeals))
	mux.Handle("POST /sandbox/{id}/employee/{eid}/deals/{bid}/imported", s.guard(s.importedSandDeals))
	mux.Handle("POST /sandbox/{id}/employee/{eid}/delete", s.guard(s.onlyAdmin(s.deleteSandEmployee)))
	mux.Handle("GET /employees", s.guard(s.showEmployees))
	mux.Handle("POST /employees", s.guard(s.createEmployee))
	mux.Handle("GET /employees/{id}", s.guard(s.showEmployee))
	mux.Handle("POST /employees/{id}", s.guard(s.saveEmployee))
	mux.Handle("POST /employees/{id}/delete", s.guard(s.deleteEmployee))
	mux.Handle("POST /employees/{id}/issue", s.guard(s.issueKey))
	mux.Handle("POST /activations/{id}/revoke", s.guard(s.revokeActivation))

	mux.Handle("GET /presets", s.guard(s.showPresets))
	mux.Handle("POST /presets", s.guard(s.onlyAdmin(s.createPreset)))
	mux.Handle("GET /presets/{id}", s.guard(s.showPreset))
	mux.Handle("GET /presets/{id}/edit", s.guard(s.onlyAdmin(s.editPreset)))
	mux.Handle("POST /presets/{id}", s.guard(s.onlyAdmin(s.savePreset)))
	mux.Handle("POST /presets/{id}/borrow", s.guard(s.onlyAdmin(s.borrowSection)))
	mux.Handle("POST /presets/{id}/delete", s.guard(s.onlyAdmin(s.deletePreset)))
	mux.Handle("POST /presets/{id}/publish", s.guard(s.onlyAdmin(s.publishPreset)))
	mux.Handle("POST /presets/{id}/rollback", s.guard(s.onlyAdmin(s.rollback)))
	mux.Handle("POST /presets/{id}/password", s.guard(s.onlyAdmin(s.savePresetPassword)))
	mux.Handle("POST /publish", s.guard(s.onlyAdmin(s.publish)))

	mux.Handle("POST /activations/find", s.guard(s.findByKey))
	mux.Handle("POST /machines/{installation}/reflash", s.guard(s.reflashMachine))

	mux.Handle("GET /audit", s.guard(s.showAudit))
	mux.Handle("GET /settings", s.guard(s.showSettings))
	mux.Handle("POST /settings/app-link", s.guard(s.onlyAdmin(s.saveAppLink)))
	mux.Handle("POST /settings/password", s.guard(s.changeOwnPassword))
	mux.Handle("POST /settings/users", s.guard(s.onlyAdmin(s.createUser)))
	mux.Handle("POST /settings/users/{id}/delete", s.guard(s.onlyAdmin(s.deleteUser)))
	mux.Handle("POST /settings/users/{id}/password", s.guard(s.onlyAdmin(s.resetUserPassword)))

	return mux
}

// ---------------------------------------------------------------- контекст

type contextKey string

const adminKey contextKey = "admin"

// guard пускает дальше только вошедших.
func (s *Server) guard(next func(http.ResponseWriter, *http.Request, model.Admin)) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cookie, err := r.Cookie(sessionCookie)
		if err != nil {
			s.sendToLogin(w, r)
			return
		}

		admin, err := s.DB.AdminBySession(r.Context(), cookie.Value)
		if err != nil {
			// Кука осталась от истёкшего или оборванного сеанса — убираем её,
			// иначе браузер будет слать её до конца времён.
			http.SetCookie(w, expiredCookie())
			s.sendToLogin(w, r)
			return
		}
		if r.Method == http.MethodPost && !s.checkCSRF(r) {
			s.rejectCSRF(w)
			return
		}
		next(w, r.WithContext(context.WithValue(r.Context(), adminKey, admin)), admin)
	})
}

// onlyAdmin пускает дальше только администратора.
//
// Проверка стоит на маршруте, а не в шаблоне: спрятать кнопку — это подсказка,
// а не запрет, и адрес страницы правки набирается руками. Техподдержке при
// этом ничего не прячется — она видит все страницы, и недоступны ей только
// действия.
func (s *Server) onlyAdmin(next func(http.ResponseWriter, *http.Request, model.Admin)) func(http.ResponseWriter, *http.Request, model.Admin) {
	return func(w http.ResponseWriter, r *http.Request, admin model.Admin) {
		if !admin.IsAdmin() {
			s.flash(r, "bad", "Это может только администратор",
				"Техподдержка правит сотрудников и выдаёт ключи; предустановки, выкладка и пользователи панели — за администратором.")
			s.back(w, r, "/overview")
			return
		}
		next(w, r, admin)
	}
}

func (s *Server) sendToLogin(w http.ResponseWriter, r *http.Request) {
	count, err := s.DB.AdminCount(r.Context())
	if err == nil && count == 0 {
		// Панель без администраторов должна предложить завести первого, а не
		// показать форму входа, в которую нечего вводить.
		http.Redirect(w, r, "/setup", http.StatusSeeOther)
		return
	}
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

func (s *Server) redirectHome(w http.ResponseWriter, r *http.Request, _ model.Admin) {
	http.Redirect(w, r, "/overview", http.StatusSeeOther)
}

// ------------------------------------------------------------------ сообщения

// Flash — сообщение, которое показывается один раз после действия.
type Flash struct {
	Kind    string // ok, warn, bad
	Title   string
	Text    string
	KeyOnce string // выданный ключ: показывается ровно один раз

	// Message — готовое сообщение сотруднику с этим же ключом внутри.
	//
	// Лежит рядом с ключом, а не собирается в браузере: те же слова видны на
	// экране, и вторая сборка развела бы показанное с отправленным.
	Message string
}

// flashStore держит сообщения в памяти.
//
// В памяти, а не в адресе страницы, и вот главная причина: сюда попадает
// выданный ключ активации, а адрес оседает в истории браузера, в журнале
// обратного прокси и в закладках. Панель на одну контору, перезапуск теряет
// разве что непрочитанное «сохранено» — цена, которую можно назвать вслух.
type flashStore struct {
	mu   sync.Mutex
	byID map[string][]Flash
}

func (f *flashStore) add(token string, flash Flash) {
	f.mu.Lock()
	defer f.mu.Unlock()

	if f.byID == nil {
		f.byID = make(map[string][]Flash)
	}
	f.byID[token] = append(f.byID[token], flash)
}

func (f *flashStore) take(token string) []Flash {
	f.mu.Lock()
	defer f.mu.Unlock()

	out := f.byID[token]
	delete(f.byID, token)
	return out
}

func (s *Server) flash(r *http.Request, kind, title, text string) {
	if cookie, err := r.Cookie(sessionCookie); err == nil {
		s.flashes.add(cookie.Value, Flash{Kind: kind, Title: title, Text: text})
	}
}

// flashTo кладёт сообщение по токену, которого в запросе ещё нет.
//
// Нужен ровно там, где сеанс заводится в этом же ответе: кука уходит вместе с
// перенаправлением, и прочитать её из запроса нельзя — она в нём ещё не
// приходила. Первая же живая проверка нашла это именно так: сообщение о том,
// что надо задать пароль конторы, не показывалось после первого входа.
func (s *Server) flashTo(token, kind, title, text string) {
	s.flashes.add(token, Flash{Kind: kind, Title: title, Text: text})
}

func (s *Server) flashKey(r *http.Request, key, message, text string) {
	if cookie, err := r.Cookie(sessionCookie); err == nil {
		s.flashes.add(cookie.Value, Flash{
			Kind: "ok", Title: "Ключ выпущен", Text: text,
			KeyOnce: key, Message: message,
		})
	}
}

// ------------------------------------------------------------------- показ

// page — общее для всех страниц.
type page struct {
	Title   string
	Section string

	// Sub — раздел внутри продукта, чтобы подшапка знала, где мы стоим.
	// У песочницы все экраны лежат в одном Section, и без этого «Пески» и
	// «Архив» подсвечивались бы одновременно.
	Sub string

	Admin   model.Admin
	Flashes []Flash
	CSRF    string
	Data    any
}

func (s *Server) render(w http.ResponseWriter, r *http.Request, name string, p page) {
	if cookie, err := r.Cookie(sessionCookie); err == nil {
		p.Flashes = s.flashes.take(cookie.Value)
		p.CSRF = s.csrfToken(cookie.Value)
	} else {
		// /login и /setup показываются без сеанса: токен цепляется за
		// отдельную предварительную куку, которую ставит этот же вызов.
		p.CSRF = s.ensureCSRFCookie(w, r)
	}

	t, ok := s.templates[name]
	if !ok {
		s.fail(w, fmt.Errorf("шаблона %q нет", name))
		return
	}

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := t.Execute(w, p); err != nil {
		// Заголовки уже ушли, поэтому подменить ответ нечем: пишем в журнал и
		// оставляем страницу оборванной — это заметнее, чем тихая пустота.
		fmt.Printf("панель: показать %s: %v\n", name, err)
	}
}

func (s *Server) fail(w http.ResponseWriter, err error) {
	http.Error(w, err.Error(), http.StatusInternalServerError)
}

// back возвращает на страницу, с которой пришли.
func (s *Server) back(w http.ResponseWriter, r *http.Request, fallback string) {
	target := r.Header.Get("Referer")
	if target == "" || !strings.HasPrefix(target, "/") {
		// Referer приходит полным адресом или не приходит вовсе, а доверять
		// чужому адресу нельзя: это открытый редирект.
		target = fallback
	}
	http.Redirect(w, r, target, http.StatusSeeOther)
}

func pathID(r *http.Request) (int64, error) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		return 0, errors.New("непонятный идентификатор в адресе")
	}
	return id, nil
}

func expiredCookie() *http.Cookie {
	return &http.Cookie{
		Name:     sessionCookie,
		Value:    "",
		Path:     "/",
		MaxAge:   -1,
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
	}
}

func sessionCookieFor(token string) *http.Cookie {
	return &http.Cookie{
		Name:  sessionCookie,
		Value: token,
		Path:  "/",
		// Secure не ставится: панель живёт внутри сети и открывается по http.
		// Поставленный флаг просто выключил бы вход, а не добавил защиты.
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   int(storage.SessionLifetime / time.Second),
	}
}
