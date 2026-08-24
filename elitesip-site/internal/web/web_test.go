package web

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"

	"github.com/koreva/elitesip-site/internal/panel"
	"github.com/koreva/elitesip-site/internal/storage"
)

type sink struct{ objects map[string][]byte }

func (s *sink) Put(_ context.Context, key string, data []byte) error {
	if s.objects == nil {
		s.objects = map[string][]byte{}
	}
	s.objects[key] = data
	return nil
}

func newServer(t *testing.T) (*Server, *storage.DB) {
	t.Helper()

	db, err := storage.Open(filepath.Join(t.TempDir(), "panel.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { db.Close() })

	out := &sink{}
	s, err := New(db,
		&panel.Issuer{DB: db, Publisher: out, Secret: []byte("секрет-сервера-для-проверки")},
		&panel.BundlePublisher{DB: db, Publisher: out},
	)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return s, db
}

// Шаблоны разбираются при запуске: ошибка в шаблоне должна ронять запуск, а не
// тот единственный экран, который откроют в неудачный момент.
func TestTemplatesParseAtStartup(t *testing.T) {
	s, _ := newServer(t)

	for _, name := range pages {
		if _, ok := s.templates[name]; !ok {
			t.Errorf("шаблон %q не разобран", name)
		}
	}
}

func TestGuardSendsAnonymousToLogin(t *testing.T) {
	s, db := newServer(t)
	db.CreateAdmin(context.Background(), nil, "eugene", "хеш")

	for _, path := range []string{"/", "/employees", "/numbers", "/presets", "/audit", "/settings"} {
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))

		if w.Code != http.StatusSeeOther {
			t.Errorf("%s: код %d, ожидался 303", path, w.Code)
		}
		if got := w.Header().Get("Location"); got != "/login" {
			t.Errorf("%s: отправило на %q", path, got)
		}
	}
}

// Панель без администраторов должна предложить завести первого, а не показать
// форму входа, в которую нечего вводить.
func TestEmptyPanelSendsToSetup(t *testing.T) {
	s, _ := newServer(t)

	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/employees", nil))

	if got := w.Header().Get("Location"); got != "/setup" {
		t.Errorf("отправило на %q, ожидался /setup", got)
	}
}

// А когда администратор есть — заведение первого должно быть закрыто, иначе
// это дверь, через которую в панель входит кто угодно из офисной сети.
func TestSetupClosesAfterFirstAdmin(t *testing.T) {
	s, db := newServer(t)
	db.CreateAdmin(context.Background(), nil, "eugene", "хеш")

	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/setup", nil))
	if got := w.Header().Get("Location"); got != "/login" {
		t.Errorf("страница заведения открыта: отправило на %q", got)
	}

	w = httptest.NewRecorder()
	s.Handler().ServeHTTP(w, post("/setup", url.Values{"login": {"чужой"}, "password": {"длинный-пароль"}}))
	if got := w.Header().Get("Location"); got != "/login" {
		t.Errorf("второй администратор завёлся через /setup")
	}

	count, _ := db.AdminCount(context.Background())
	if count != 1 {
		t.Errorf("администраторов стало %d", count)
	}
}

func TestLoginAndLogout(t *testing.T) {
	s, db := newServer(t)
	hash, _ := panel.HashPassword("пароль-панели")
	db.CreateAdmin(context.Background(), nil, "eugene", hash)

	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, post("/login", url.Values{"login": {"eugene"}, "password": {"пароль-панели"}}))
	if w.Code != http.StatusSeeOther {
		t.Fatalf("вход дал код %d", w.Code)
	}

	cookie := sessionFrom(t, w)
	page := httptest.NewRequest(http.MethodGet, "/employees", nil)
	page.AddCookie(cookie)

	w = httptest.NewRecorder()
	s.Handler().ServeHTTP(w, page)
	if w.Code != http.StatusOK {
		t.Fatalf("после входа страница дала %d", w.Code)
	}

	out := httptest.NewRequest(http.MethodPost, "/logout", nil)
	out.AddCookie(cookie)
	w = httptest.NewRecorder()
	s.Handler().ServeHTTP(w, out)

	again := httptest.NewRequest(http.MethodGet, "/employees", nil)
	again.AddCookie(cookie)
	w = httptest.NewRecorder()
	s.Handler().ServeHTTP(w, again)
	if w.Header().Get("Location") != "/login" {
		t.Error("после выхода сеанс всё ещё пускает")
	}
}

// Один ответ на все случаи: подбирающему незачем знать, какое из имён
// существует.
func TestLoginTellsNothingExtra(t *testing.T) {
	s, db := newServer(t)
	hash, _ := panel.HashPassword("пароль-панели")
	db.CreateAdmin(context.Background(), nil, "eugene", hash)

	wrongName := httptest.NewRecorder()
	s.Handler().ServeHTTP(wrongName, post("/login", url.Values{"login": {"нет-такого"}, "password": {"пароль-панели"}}))

	wrongPassword := httptest.NewRecorder()
	s.Handler().ServeHTTP(wrongPassword, post("/login", url.Values{"login": {"eugene"}, "password": {"не-тот"}}))

	if wrongName.Body.String() != wrongPassword.Body.String() {
		t.Error("ответы про чужое имя и про неверный пароль различаются")
	}
	if !strings.Contains(wrongName.Body.String(), "Неверное имя или пароль") {
		t.Error("нет сообщения об отказе")
	}
}

// Выпуск ключа полным кругом через веб: страница показывает ключ ровно один
// раз и больше не показывает никогда.
func TestIssuedKeyIsShownOnce(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	admin, _ := db.CreateAdmin(ctx, nil, "eugene", hash)
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	number, _ := db.CreateNumber(ctx, nil, "172", "секрет-172", "")
	preset, _ := db.CreatePreset(ctx, nil, "Менеджер")
	db.SaveRevision(ctx, nil, preset.ID, 2, []byte(`{}`), "")
	employee, _ := db.CreateEmployee(ctx, nil, "Пётр", &preset.ID)
	db.AssignNumber(ctx, nil, employee.ID, number.ID)
	db.SetSetting(ctx, nil, storage.SettingAdminPassword, "пароль-конторы")

	issue := post("/employees/1/issue", url.Values{"note": {"ноутбук"}})
	issue.AddCookie(cookie)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, issue)
	if w.Code != http.StatusSeeOther {
		t.Fatalf("выпуск дал код %d", w.Code)
	}

	first := httptest.NewRequest(http.MethodGet, "/employees/1", nil)
	first.AddCookie(cookie)
	w = httptest.NewRecorder()
	s.Handler().ServeHTTP(w, first)

	body := w.Body.String()
	if !strings.Contains(body, "Ключ выпущен") || !strings.Contains(body, "key-value") {
		t.Fatal("выпущенный ключ не показан")
	}

	second := httptest.NewRequest(http.MethodGet, "/employees/1", nil)
	second.AddCookie(cookie)
	w = httptest.NewRecorder()
	s.Handler().ServeHTTP(w, second)

	if strings.Contains(w.Body.String(), "key-value") {
		t.Error("ключ показан второй раз — он не должен восстанавливаться ниоткуда")
	}
}

// Карточка говорит, чего не хватает, до нажатия: отказ после нажатия — тот же
// отказ, только позже и обиднее.
func TestEmployeeCardExplainsWhatBlocksIssue(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	admin, _ := db.CreateAdmin(ctx, nil, "eugene", hash)
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	db.CreateEmployee(ctx, nil, "Без всего", nil)

	r := httptest.NewRequest(http.MethodGet, "/employees/1", nil)
	r.AddCookie(cookie)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)

	body := w.Body.String()
	if !strings.Contains(body, "Ключ выпустить нельзя") {
		t.Fatal("карточка не объясняет, почему ключ недоступен")
	}
	if !strings.Contains(body, "не закреплён номер") {
		t.Errorf("не сказано, чего именно не хватает")
	}
}

// Ключ не должен оседать в адресе: адрес попадает в историю браузера, в
// журнал обратного прокси и в закладки.
func TestKeyNeverTravelsInURL(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	admin, _ := db.CreateAdmin(ctx, nil, "eugene", hash)
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	number, _ := db.CreateNumber(ctx, nil, "172", "секрет", "")
	preset, _ := db.CreatePreset(ctx, nil, "Менеджер")
	db.SaveRevision(ctx, nil, preset.ID, 2, []byte(`{}`), "")
	employee, _ := db.CreateEmployee(ctx, nil, "Пётр", &preset.ID)
	db.AssignNumber(ctx, nil, employee.ID, number.ID)
	db.SetSetting(ctx, nil, storage.SettingAdminPassword, "пароль-конторы")

	issue := post("/employees/1/issue", nil)
	issue.AddCookie(cookie)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, issue)

	location := w.Header().Get("Location")
	if strings.ContainsAny(location, "?&") {
		t.Errorf("в адресе перенаправления что-то есть: %q", location)
	}
}

func post(path string, values url.Values) *http.Request {
	r := httptest.NewRequest(http.MethodPost, path, strings.NewReader(values.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	return r
}

func sessionFrom(t *testing.T, w *httptest.ResponseRecorder) *http.Cookie {
	t.Helper()
	for _, c := range w.Result().Cookies() {
		if c.Name == sessionCookie {
			return c
		}
	}
	t.Fatal("сеанс не заведён")
	return nil
}
