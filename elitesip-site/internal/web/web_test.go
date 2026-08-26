package web

import (
	"context"
	"crypto/ed25519"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/koreva/elitesip-site/internal/model"
	"github.com/koreva/elitesip-site/internal/panel"
	"github.com/koreva/elitesip-site/internal/preset"
	"github.com/koreva/elitesip-site/internal/publish"
	"github.com/koreva/elitesip-site/internal/sand"
	"github.com/koreva/elitesip-site/internal/storage"
)

// sink — бакет в памяти: и кладём, и читаем.
type sink struct{ objects map[string][]byte }

func (s *sink) Put(_ context.Context, key string, data []byte) error {
	if s.objects == nil {
		s.objects = map[string][]byte{}
	}
	s.objects[key] = data
	return nil
}

func (s *sink) Delete(_ context.Context, key string) error {
	delete(s.objects, key)
	return nil
}

func (s *sink) Get(_ context.Context, key string) ([]byte, error) {
	data, ok := s.objects[key]
	if !ok {
		return nil, publish.ErrNoObject
	}
	return data, nil
}

func (s *sink) List(_ context.Context, prefix string) ([]string, error) {
	var out []string
	for key := range s.objects {
		if strings.HasPrefix(key, prefix) {
			out = append(out, key)
		}
	}
	sort.Strings(out)
	return out, nil
}

func newServer(t *testing.T) (*Server, *storage.DB) {
	t.Helper()

	db, err := storage.Open(filepath.Join(t.TempDir(), "panel.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	sandDB, err := sand.Open(filepath.Join(t.TempDir(), "sand.db"))
	if err != nil {
		t.Fatalf("Open sand: %v", err)
	}
	t.Cleanup(func() { sandDB.Close() })

	// Ключ подписи настоящий, а не пустой: без него выкладка не проходит вовсе,
	// и проверять на ней было бы нечего.
	_, signing, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatalf("ключ подписи: %v", err)
	}

	out := &sink{}
	machines := &panel.MachineWriter{Publisher: out, SigningKey: signing}
	secret := []byte("секрет-сервера-для-проверки")
	s, err := New(db, sandDB,
		&panel.Issuer{DB: db, Publisher: out, Machines: machines, Secret: secret},
		&panel.BundlePublisher{DB: db, Publisher: out, SigningKey: signing},
		&panel.MarkCollector{DB: db, Reader: out},
		&panel.Revoker{DB: db, Machines: machines, Deleter: out},
		&panel.AccessPublisher{DB: db, Machines: machines},
		secret,
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

	for _, path := range []string{"/", "/overview", "/employees", "/presets", "/audit", "/settings"} {
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
	s.Handler().ServeHTTP(w, anonPost(s, "/setup", url.Values{"login": {"чужой"}, "password": {"длинный-пароль"}}))
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
	s.Handler().ServeHTTP(w, anonPost(s, "/login", url.Values{"login": {"eugene"}, "password": {"пароль-панели"}}))
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

	out := s.authed(cookie, "/logout", nil)
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
	s.Handler().ServeHTTP(wrongName, anonPost(s, "/login", url.Values{"login": {"нет-такого"}, "password": {"пароль-панели"}}))

	wrongPassword := httptest.NewRecorder()
	s.Handler().ServeHTTP(wrongPassword, anonPost(s, "/login", url.Values{"login": {"eugene"}, "password": {"не-тот"}}))

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

	preset, _ := db.CreatePreset(ctx, nil, "Менеджер")
	db.SaveRevision(ctx, nil, preset.ID, 2, []byte(`{}`), "")
	db.CreateEmployee(ctx, nil, model.Employee{
		Name: "Пётр", Number: "172", SIPPassword: "секрет-172", PresetID: &preset.ID,
	})
	db.SetPresetAdminPassword(ctx, nil, preset.ID, "пароль-предустановки")

	issue := s.authed(cookie, "/employees/1/issue", url.Values{"note": {"ноутбук"}})
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

	db.CreateEmployee(ctx, nil, model.Employee{Name: "Без всего"})

	r := httptest.NewRequest(http.MethodGet, "/employees/1", nil)
	r.AddCookie(cookie)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)

	body := w.Body.String()
	if !strings.Contains(body, "Ключ выпустить нельзя") {
		t.Fatal("карточка не объясняет, почему ключ недоступен")
	}
	if !strings.Contains(body, "не заполнены номер и SIP-пароль") {
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

	preset, _ := db.CreatePreset(ctx, nil, "Менеджер")
	db.SaveRevision(ctx, nil, preset.ID, 2, []byte(`{}`), "")
	db.CreateEmployee(ctx, nil, model.Employee{
		Name: "Пётр", Number: "172", SIPPassword: "секрет", PresetID: &preset.ID,
	})
	db.SetPresetAdminPassword(ctx, nil, preset.ID, "пароль-предустановки")

	issue := s.authed(cookie, "/employees/1/issue", nil)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, issue)

	location := w.Header().Get("Location")
	if strings.ContainsAny(location, "?&") {
		t.Errorf("в адресе перенаправления что-то есть: %q", location)
	}
}

// Первый экран после входа — обзор, а не список людей: он объясняет, с чего
// начать, тому, кто наших документов не читал.
func TestRootGoesToOverview(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	admin, _ := db.CreateAdmin(ctx, nil, "eugene", hash)
	token, _ := db.StartSession(ctx, admin.ID)

	r := httptest.NewRequest(http.MethodGet, "/", nil)
	r.AddCookie(&http.Cookie{Name: sessionCookie, Value: token})
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)

	if got := w.Header().Get("Location"); got != "/overview" {
		t.Errorf("корень ведёт на %q", got)
	}
}

// Свежая панель объясняет, чего в ней не хватает, — иначе первый ключ не
// выпускается, а почему, видно только по отказу в карточке.
func TestOverviewExplainsUnconfiguredPanel(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	admin, _ := db.CreateAdmin(ctx, nil, "eugene", hash)
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	r := httptest.NewRequest(http.MethodGet, "/overview", nil)
	r.AddCookie(cookie)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)

	body := w.Body.String()
	for _, want := range []string{
		// Про пароль здесь не спрашиваем: предустановок нет вовсе, а пароль —
		// поле предустановки, и жаловаться не на что.
		"Нет ни одной предустановки",
		"Не задан адрес, откуда качать приложение",
		// Инструкций на обзоре больше нет: убраны 25 августа 2026 до того, как
		// будут написаны заново. Остались объяснения того, чего не хватает —
		// они и есть работа этого экрана на свежей панели.
	} {
		if !strings.Contains(body, want) {
			t.Errorf("на обзоре нет %q", want)
		}
	}

	// Плитки «отставшие по версии» быть не должно: панели о версиях машин
	// узнать неоткуда, и пустая плитка без объяснения читается как поломка.
	if strings.Contains(body, "отставш") {
		t.Error("показана плитка, которой пока нечем наполниться")
	}
}

// Хвост со ссылкой на то место, где чинится: без ссылки он сообщает о беде и
// оставляет искать, где её править.
func TestOverviewTailLinksToWhereItIsFixed(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	admin, _ := db.CreateAdmin(ctx, nil, "eugene", hash)
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	db.CreateEmployee(ctx, nil, model.Employee{Name: "Без всего"})

	r := httptest.NewRequest(http.MethodGet, "/overview", nil)
	r.AddCookie(cookie)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)

	body := w.Body.String()
	if !strings.Contains(body, `href="/employees/1"`) {
		t.Error("хвост не ведёт в карточку")
	}
	if !strings.Contains(body, "ключ такому не выпустится") {
		t.Error("не сказано, чем этот хвост плох")
	}
}

// Главный путь панели: одна форма заводит человека и сразу отдаёт ключ вместе
// с готовым сообщением. Раздельные «завести» и «выпустить» — лишнее нажатие
// каждую неделю и один забытый ключ на десяток заведений.
func TestCreateAndIssueInOneAction(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	admin, _ := db.CreateAdmin(ctx, nil, "eugene", hash)
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	preset, _ := db.CreatePreset(ctx, nil, "Менеджер")
	db.SaveRevision(ctx, nil, preset.ID, 2, []byte(`{}`), "")
	db.SetPresetAdminPassword(ctx, nil, preset.ID, "пароль-предустановки")
	db.SetSetting(ctx, nil, storage.SettingAppLink, "https://elitesip.vip/download")

	create := s.authed(cookie, "/employees", url.Values{
		"name":         {"Пётр Смирнов"},
		"number":       {"172"},
		"sip_password": {"секрет-172"},
		"preset_id":    {strconv.FormatInt(preset.ID, 10)},
	})
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, create)
	if got := w.Header().Get("Location"); got != "/employees/1" {
		t.Fatalf("после заведения отправило на %q", got)
	}

	card := httptest.NewRequest(http.MethodGet, "/employees/1", nil)
	card.AddCookie(cookie)
	w = httptest.NewRecorder()
	s.Handler().ServeHTTP(w, card)

	body := w.Body.String()
	if !strings.Contains(body, "Ключ выпущен") || !strings.Contains(body, "key-value") {
		t.Fatal("ключ не показан сразу за формой")
	}
	if !strings.Contains(body, "Скопировать сообщение") {
		t.Error("готового сообщения сотруднику нет")
	}
	if !strings.Contains(body, "elitesip.vip/download") {
		t.Error("в сообщении нет адреса, откуда качать приложение")
	}

	list, err := db.ListActivations(ctx, 1)
	if err != nil || len(list) != 1 {
		t.Fatalf("активаций записано %d (%v)", len(list), err)
	}
}

// Не из чего собрать пакет — сотрудник всё равно остаётся заведённым: человек
// вбил имя, номер и пароль, и терять их из-за незаполненной настройки не за что.
func TestCreateKeepsEmployeeWhenKeyCannotBeIssued(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	admin, _ := db.CreateAdmin(ctx, nil, "eugene", hash)
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	create := s.authed(cookie, "/employees", url.Values{"name": {"Без всего"}})
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, create)

	card := httptest.NewRequest(http.MethodGet, "/employees/1", nil)
	card.AddCookie(cookie)
	w = httptest.NewRecorder()
	s.Handler().ServeHTTP(w, card)

	body := w.Body.String()
	if !strings.Contains(body, "Сотрудник заведён, но ключ не выпущен") {
		t.Error("не сказано, что ключа не будет")
	}
	if !strings.Contains(body, "Ключ выпустить нельзя") {
		t.Error("карточка не объясняет, чего не хватает")
	}
	if _, err := db.EmployeeByID(ctx, 1); err != nil {
		t.Errorf("сотрудник не сохранился: %v", err)
	}
}

// Раздела «Номера» больше нет: номер живёт и умирает вместе с сотрудником, и
// второе место, где то же самое можно править, было бы вторым источником одной
// правды.
func TestNumbersSectionIsGone(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	admin, _ := db.CreateAdmin(ctx, nil, "eugene", hash)
	token, _ := db.StartSession(ctx, admin.ID)

	r := httptest.NewRequest(http.MethodGet, "/numbers", nil)
	r.AddCookie(&http.Cookie{Name: sessionCookie, Value: token})
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)

	if w.Code != http.StatusNotFound {
		t.Errorf("/numbers ответил %d, ожидалось 404", w.Code)
	}
}

// Удаление сотрудника уносит его машины и предупреждает про пароль пира: панель
// после активации до машины не дотягивается, и это единственное, чем её
// останавливают.
func TestDeleteEmployeeWarnsAboutPeerPassword(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	admin, _ := db.CreateAdmin(ctx, nil, "eugene", hash)
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	employee, _ := db.CreateEmployee(ctx, nil, model.Employee{
		Name: "Анна Иванова", Number: "172", SIPPassword: "секрет",
	})

	del := s.authed(cookie, "/employees/1/delete", nil)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, del)
	if got := w.Header().Get("Location"); got != "/employees" {
		t.Fatalf("после удаления отправило на %q", got)
	}

	list := httptest.NewRequest(http.MethodGet, "/employees", nil)
	list.AddCookie(cookie)
	w = httptest.NewRecorder()
	s.Handler().ServeHTTP(w, list)

	body := w.Body.String()
	if !strings.Contains(body, "сменят SIP-пароль пира") {
		t.Error("не предупредило про пароль пира на АТС")
	}
	if strings.Contains(body, "Анна Иванова") {
		t.Error("удалённый сотрудник остался в списке")
	}

	if _, err := db.EmployeeByID(ctx, employee.ID); err == nil {
		t.Error("карточка читается после удаления")
	}
}

// Предустановка подставляется та же, что в прошлый раз: стажёры приходят
// пачками и все по одной.
func TestLastPresetIsOfferedAgain(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	admin, _ := db.CreateAdmin(ctx, nil, "eugene", hash)
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	preset, _ := db.CreatePreset(ctx, nil, "Менеджер")
	db.CreatePreset(ctx, nil, "Секретарь")

	create := s.authed(cookie, "/employees", url.Values{
		"name":      {"Пётр"},
		"number":    {"172"},
		"preset_id": {strconv.FormatInt(preset.ID, 10)},
	})
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, create)

	stored, err := db.Setting(ctx, storage.SettingLastPreset)
	if err != nil || stored != strconv.FormatInt(preset.ID, 10) {
		t.Fatalf("выбор не запомнился: %q (%v)", stored, err)
	}

	// Форма заведения живёт в разделе «Выдать ключ»: со страницы списка она
	// уехала 25 августа 2026, чтобы одно действие не жило в двух местах.
	list := httptest.NewRequest(http.MethodGet, "/keys", nil)
	list.AddCookie(cookie)
	w = httptest.NewRecorder()
	s.Handler().ServeHTTP(w, list)

	if !strings.Contains(w.Body.String(), "selected>Менеджер") {
		t.Error("прошлая предустановка не подставлена в форму заведения")
	}
}

// Перед выкладкой видно словами, что уедет: список читает техподдержка перед
// тем, как правка станет обязательным обновлением на всех машинах.
func TestPendingChangesAreShownInWords(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	admin, _ := db.CreateAdmin(ctx, nil, "eugene", hash)
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	p, _ := db.CreatePreset(ctx, nil, "Менеджер")
	db.SaveRevision(ctx, nil, p.ID, preset.SchemaVersion,
		[]byte(`{"siteAddresses":{"office":"192.168.1.2","remote":"crm.elitesochi.com"}}`), "первая")
	if _, err := s.Publisher.Publish(ctx, nil); err != nil {
		t.Fatalf("первая выкладка: %v", err)
	}
	db.SaveRevision(ctx, nil, p.ID, preset.SchemaVersion,
		[]byte(`{"siteAddresses":{"office":"192.168.1.2","remote":"crm2.elitesochi.com"}}`), "переезд")

	r := httptest.NewRequest(http.MethodGet, "/presets/1", nil)
	r.AddCookie(cookie)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)

	body := w.Body.String()
	if !strings.Contains(body, "Не выложено") {
		t.Fatal("не сказано, что ревизия не уехала")
	}
	if !strings.Contains(body, "crm2.elitesochi.com") || !strings.Contains(body, "Адрес АТС снаружи") {
		t.Errorf("изменение не показано словами")
	}
	// Технического диффа быть не должно — его пролистают не читая.
	if strings.Contains(body, "siteAddresses") {
		t.Error("на экран уехал технический дифф")
	}
}

// Откат ложится новой ревизией поверх и выкладывается сразу: откатываются,
// когда на рабочих местах уже что-то сломалось.
func TestRollbackCreatesNewRevisionAndPublishesIt(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	admin, _ := db.CreateAdmin(ctx, nil, "eugene", hash)
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	p, _ := db.CreatePreset(ctx, nil, "Менеджер")
	first, _ := db.SaveRevision(ctx, nil, p.ID, preset.SchemaVersion,
		[]byte(`{"conference":{"featureCode":"*3","roomExtension":"8000"}}`), "первая")
	db.SaveRevision(ctx, nil, p.ID, preset.SchemaVersion,
		[]byte(`{"conference":{"featureCode":"*9","roomExtension":"8000"}}`), "сломали")

	back := s.authed(cookie, "/presets/1/rollback", url.Values{
		"revision_id": {strconv.FormatInt(first.ID, 10)},
	})
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, back)

	revisions, err := db.ListRevisions(ctx, p.ID)
	if err != nil {
		t.Fatalf("ListRevisions: %v", err)
	}
	if len(revisions) != 3 {
		t.Fatalf("ревизий %d, ожидалось 3 — откат обязан лечь поверх, а не переписать прошлое", len(revisions))
	}

	latest := revisions[0]
	if string(latest.Payload) != string(first.Payload) {
		t.Errorf("откат вернул не то: %s", latest.Payload)
	}
	if !latest.Published() {
		t.Error("откат не выложен — а он выкладывается сразу")
	}
	if !strings.Contains(latest.Note, "откат на ревизию 1") {
		t.Errorf("пометка отката вышла такая: %q", latest.Note)
	}
}

// Ревизия чужой предустановки откатом не берётся: идентификатор приходит из
// формы, и проверять его принадлежность — не роскошь.
func TestRollbackRefusesForeignRevision(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	admin, _ := db.CreateAdmin(ctx, nil, "eugene", hash)
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	db.CreatePreset(ctx, nil, "Менеджер")
	other, _ := db.CreatePreset(ctx, nil, "Секретарь")
	foreign, _ := db.SaveRevision(ctx, nil, other.ID, preset.SchemaVersion, []byte(`{}`), "чужая")

	back := s.authed(cookie, "/presets/1/rollback", url.Values{
		"revision_id": {strconv.FormatInt(foreign.ID, 10)},
	})
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, back)

	revisions, _ := db.ListRevisions(ctx, 1)
	if len(revisions) != 0 {
		t.Errorf("чужая ревизия перетекла в другую предустановку: %d", len(revisions))
	}
}

// Без токена формы POST от вошедшего пользователя отклоняется, даже с
// настоящей курой сеанса: токен формы и сеанс — два разных условия.
func TestGuardRejectsPostWithoutCSRFToken(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	admin, _ := db.CreateAdmin(ctx, nil, "eugene", hash)
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	r := post("/employees", url.Values{"name": {"Пётр"}})
	r.AddCookie(cookie)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)

	if w.Code != http.StatusForbidden {
		t.Fatalf("код %d, ожидался 403", w.Code)
	}
	if people, _ := db.ListEmployees(ctx, storage.EmployeeFilter{}); len(people) != 0 {
		t.Error("сотрудник создался без токена формы")
	}
}

// Чужой (неверный) токен формы отклоняется так же, как отсутствующий: и
// то, и другое — не то, что вывела render() для этого сеанса.
func TestGuardRejectsPostWithWrongCSRFToken(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	admin, _ := db.CreateAdmin(ctx, nil, "eugene", hash)
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	r := post("/employees", url.Values{"name": {"Пётр"}, csrfField: {"чужой-токен"}})
	r.AddCookie(cookie)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)

	if w.Code != http.StatusForbidden {
		t.Fatalf("код %d, ожидался 403", w.Code)
	}
}

// Та же форма с верным токеном (тем, что кладёт браузер после показа
// страницы) обязана продолжать работать — защита не должна ломать то, что
// сама же требует.
func TestGuardAcceptsPostWithValidCSRFToken(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	admin, _ := db.CreateAdmin(ctx, nil, "eugene", hash)
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	r := s.authed(cookie, "/employees", url.Values{"name": {"Пётр"}})
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)

	if w.Code != http.StatusSeeOther {
		t.Fatalf("код %d при верном токене формы", w.Code)
	}
	if people, _ := db.ListEmployees(ctx, storage.EmployeeFilter{}); len(people) != 1 {
		t.Error("сотрудник не создался с верным токеном формы")
	}
}

// У /login сеанса ещё нет — токен цепляется за предварительную куку. Без неё
// POST отклоняется так же, как и в обычных формах.
func TestLoginRejectsPostWithoutCSRFToken(t *testing.T) {
	s, db := newServer(t)
	hash, _ := panel.HashPassword("пароль-панели")
	db.CreateAdmin(context.Background(), nil, "eugene", hash)

	r := post("/login", url.Values{"login": {"eugene"}, "password": {"пароль-панели"}})
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)

	if w.Code != http.StatusForbidden {
		t.Errorf("код %d, ожидался 403", w.Code)
	}
}

// Полный круг: GET /login выдаёт куку и печатает в форму токен от неё же —
// POST с этой парой обязан пройти. Проверяет саму связку render/ensureCSRFCookie,
// а не только ручную сборку токена в anonPost.
func TestLoginFormTokenRoundTrips(t *testing.T) {
	s, db := newServer(t)
	hash, _ := panel.HashPassword("пароль-панели")
	db.CreateAdmin(context.Background(), nil, "eugene", hash)

	get := httptest.NewRequest(http.MethodGet, "/login", nil)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, get)

	var preAuth *http.Cookie
	for _, c := range w.Result().Cookies() {
		if c.Name == csrfCookie {
			preAuth = c
		}
	}
	if preAuth == nil {
		t.Fatal("GET /login не выдал предварительную CSRF-куку")
	}
	formToken := csrfTokenFromHTML(t, w.Body.String())

	login := post("/login", url.Values{"login": {"eugene"}, "password": {"пароль-панели"}, csrfField: {formToken}})
	login.AddCookie(preAuth)
	w = httptest.NewRecorder()
	s.Handler().ServeHTTP(w, login)

	if w.Code != http.StatusSeeOther {
		t.Fatalf("вход с токеном из формы дал код %d", w.Code)
	}
}

// csrfTokenFromHTML достаёт значение скрытого поля из отданной формы — как
// это сделал бы браузер, отправляя её обратно.
func csrfTokenFromHTML(t *testing.T, body string) string {
	t.Helper()
	marker := `name="csrf" value="`
	i := strings.Index(body, marker)
	if i < 0 {
		t.Fatal("в форме нет скрытого поля csrf")
	}
	rest := body[i+len(marker):]
	j := strings.IndexByte(rest, '"')
	if j < 0 {
		t.Fatal("не удалось прочитать значение поля csrf")
	}
	return rest[:j]
}

func post(path string, values url.Values) *http.Request {
	r := httptest.NewRequest(http.MethodPost, path, strings.NewReader(values.Encode()))
	r.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	return r
}

// authed строит POST от вошедшего пользователя — с курительной сеанса и
// верным CSRF-токеном, как их кладёт браузер после показа формы. Помогает
// не повторять вычисление токена в каждом тесте, который уже был написан на
// голый post() до появления защиты от подделки запросов.
func (s *Server) authed(cookie *http.Cookie, path string, values url.Values) *http.Request {
	values = cloneValues(values)
	values.Set(csrfField, s.csrfToken(cookie.Value))
	r := post(path, values)
	r.AddCookie(cookie)
	return r
}

// anonPost строит POST без сеанса — для /login и /setup, где токен цепляется
// за предварительную CSRF-куку, а не за сеанс.
func anonPost(s *Server, path string, values url.Values) *http.Request {
	// Кука несёт только ASCII (RFC 6265) — не Server.ensureCSRFCookie, а
	// значение здесь набрано руками для теста, вот и ограничение.
	const raw = "test-preauth-csrf-cookie"
	values = cloneValues(values)
	values.Set(csrfField, s.csrfToken(raw))
	r := post(path, values)
	r.AddCookie(&http.Cookie{Name: csrfCookie, Value: raw})
	return r
}

func cloneValues(v url.Values) url.Values {
	out := url.Values{}
	for k, vals := range v {
		out[k] = append([]string(nil), vals...)
	}
	return out
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

// Сотрудник прислал ключ и говорит, что не работает: панель обязана ответить,
// чей он и что с ним. Опознание по первым четырём знакам для этого не годится —
// они не уникальны.
func TestFindByKeyLandsOnEmployeeCard(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	admin, _ := db.CreateAdmin(ctx, nil, "admin", "пароль-длиннее-восьми")
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	preset, _ := db.CreatePreset(ctx, nil, "Менеджер")
	db.SaveRevision(ctx, nil, preset.ID, 2, []byte(`{}`), "")
	employee, _ := db.CreateEmployee(ctx, nil, model.Employee{
		Name: "Пётр", Number: "172", SIPPassword: "секрет-172", PresetID: &preset.ID,
	})
	db.SetPresetAdminPassword(ctx, nil, preset.ID, "пароль-предустановки")

	key, saved, err := s.Issuer.Issue(ctx, nil, employee.ID, "")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}

	// Ключ приходит из переписки как есть — с дефисами и переносом строки.
	find := s.authed(cookie, "/activations/find", url.Values{"key": {key.String() + "\n"}})
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, find)

	if w.Code != http.StatusSeeOther {
		t.Fatalf("код %d, ожидалось перенаправление", w.Code)
	}
	location := w.Header().Get("Location")
	want := "/employees/" + strconv.FormatInt(employee.ID, 10)
	if !strings.HasPrefix(location, want) {
		t.Errorf("отправило на %q, ожидалась карточка %q", location, want)
	}
	if !strings.Contains(location, "found="+strconv.FormatInt(saved.ID, 10)) {
		t.Errorf("в адресе нет подсветки строки: %q", location)
	}
}

// Отвечаем прямо: круг лиц свой, а при шестидесяти битах оракул «существует ли
// такой ключ» не даёт подбирающему ничего.
func TestFindByKeySaysWhenNothingFound(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	admin, _ := db.CreateAdmin(ctx, nil, "admin", "пароль-длиннее-восьми")
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	find := s.authed(cookie, "/activations/find", url.Values{"key": {"K7M2-9XQP-4TFB"}})
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, find)

	list := httptest.NewRequest(http.MethodGet, "/employees", nil)
	list.AddCookie(cookie)
	shown := httptest.NewRecorder()
	s.Handler().ServeHTTP(shown, list)

	if !strings.Contains(shown.Body.String(), "Такого ключа нет") {
		t.Error("панель не сказала, что ключа нет")
	}
}

// Карточка машины: молчание показывается состоянием, а не датой мелким
// шрифтом, и у живой активированной машины есть кнопка перепрошивки.
func TestEmployeeCardShowsSilenceAndReflash(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	admin, _ := db.CreateAdmin(ctx, nil, "admin", "пароль-длиннее-восьми")
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	preset, _ := db.CreatePreset(ctx, nil, "Менеджер")
	db.SaveRevision(ctx, nil, preset.ID, 2, []byte(`{}`), "")
	employee, _ := db.CreateEmployee(ctx, nil, model.Employee{
		Name: "Пётр", Number: "172", SIPPassword: "секрет-172", PresetID: &preset.ID,
	})
	db.SetPresetAdminPassword(ctx, nil, preset.ID, "пароль-предустановки")

	_, saved, err := s.Issuer.Issue(ctx, nil, employee.ID, "")
	if err != nil {
		t.Fatalf("Issue: %v", err)
	}
	if err := db.MarkFetched(ctx, saved.ObjectKey, time.Now()); err != nil {
		t.Fatalf("MarkFetched: %v", err)
	}
	// Машина отметилась неделю назад и с тех пор молчит: её могли сбросить на
	// месте и увезти — панель об этом не узнаёт никогда.
	if _, err := db.SaveCheckin(ctx, model.Checkin{
		InstallationID: saved.InstallationID,
		LastSeenAt:     time.Now().Add(-7 * 24 * time.Hour),
		AppVersion:     "0.1.28",
	}); err != nil {
		t.Fatalf("SaveCheckin: %v", err)
	}

	card := httptest.NewRequest(http.MethodGet,
		"/employees/"+strconv.FormatInt(employee.ID, 10), nil)
	card.AddCookie(cookie)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, card)

	body := w.Body.String()
	if !strings.Contains(body, "молчит") {
		t.Error("молчание не показано состоянием")
	}
	if !strings.Contains(body, "/reflash") {
		t.Error("у активированной машины нет кнопки перепрошивки")
	}
}

// Техподдержка делает всю работу с людьми, но предустановки только смотрит.
//
// Проверка стоит на маршруте, а не на кнопке: спрятанная кнопка — подсказка, а
// адрес страницы правки набирается руками.
func TestSupportSeesEverythingAndEditsPeopleOnly(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	support, err := db.CreateAdminWithRole(ctx, nil, "olga", hash, model.RoleSupport)
	if err != nil {
		t.Fatalf("CreateAdminWithRole: %v", err)
	}
	token, _ := db.StartSession(ctx, support.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	preset, _ := db.CreatePreset(ctx, nil, "Менеджер")
	card := "/presets/" + strconv.FormatInt(preset.ID, 10)

	// Смотреть можно всё, включая карточку предустановки.
	for _, path := range []string{"/overview", "/keys", "/employees", "/presets", card, "/audit", "/settings"} {
		r := httptest.NewRequest(http.MethodGet, path, nil)
		r.AddCookie(cookie)
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, r)
		if w.Code != http.StatusOK {
			t.Errorf("%s закрыт для техподдержки: %d", path, w.Code)
		}
	}

	// Заводить сотрудников — её работа.
	create := s.authed(cookie, "/employees", url.Values{"name": {"Пётр"}, "number": {"172"}})
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, create)
	if people, _ := db.ListEmployees(ctx, storage.EmployeeFilter{}); len(people) != 1 {
		t.Error("техподдержка не смогла завести сотрудника")
	}

	// А править предустановку — нет, и правка не сохраняется.
	for _, path := range []string{card, card + "/publish", card + "/password", "/publish"} {
		r := s.authed(cookie, path, url.Values{"admin_password": {"чужой"}})
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, r)
	}
	if _, err := db.LatestRevision(ctx, preset.ID); err == nil {
		t.Error("техподдержка сохранила ревизию предустановки")
	}
	if stored, _ := db.PresetAdminPassword(ctx, preset.ID); stored != "" {
		t.Errorf("техподдержка сменила административный пароль: %q", stored)
	}

	// И страница правки ей не открывается, хотя адрес известен.
	edit := httptest.NewRequest(http.MethodGet, card+"/edit", nil)
	edit.AddCookie(cookie)
	w = httptest.NewRecorder()
	s.Handler().ServeHTTP(w, edit)
	if w.Code == http.StatusOK {
		t.Error("страница правки открылась техподдержке")
	}
}

// Опасное перед выкладкой стоит отдельно и целиком, а безобидное свёрнуто.
//
// Это то, что заменило собой замок на адресах АТС: замок сторожил случайное
// движение в форме, а окно выкладки — последнее место, где правку читают перед
// тем, как она станет обязательным обновлением на всех машинах разом.
func TestDangerousChangesStandApartBeforePublish(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	admin, _ := db.CreateAdmin(ctx, nil, "eugene", hash)
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	preset, _ := db.CreatePreset(ctx, nil, "Менеджер")
	first, _ := db.SaveRevision(ctx, nil, preset.ID, 1, []byte(
		`{"siteAddresses":{"office":"10.0.0.5","remote":"crm.elitesochi.com"},
		  "conference":{"featureCode":"*3","roomExtension":"8000"}}`), "")
	if err := db.MarkPublished(ctx, nil, first.ID); err != nil {
		t.Fatalf("MarkPublished: %v", err)
	}
	// Меняется и адрес АТС, и безобидный код конференции.
	if _, err := db.SaveRevision(ctx, nil, preset.ID, 1, []byte(
		`{"siteAddresses":{"office":"10.0.0.5","remote":"crm2.elitesochi.com"},
		  "conference":{"featureCode":"*4","roomExtension":"8000"}}`), ""); err != nil {
		t.Fatalf("SaveRevision: %v", err)
	}

	r := httptest.NewRequest(http.MethodGet, "/presets/"+strconv.FormatInt(preset.ID, 10), nil)
	r.AddCookie(cookie)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)
	body := w.Body.String()

	if !strings.Contains(body, "Меняется связь с АТС") {
		t.Error("опасное изменение не выделено отдельно")
	}
	danger := strings.Index(body, "Адрес АТС снаружи")
	ordinary := strings.Index(body, "Остальные изменения")
	if danger < 0 || ordinary < 0 {
		t.Fatalf("изменения показаны не полностью: опасное %d, обычное %d", danger, ordinary)
	}
	if danger > ordinary {
		t.Error("опасное стоит ниже безобидного — читать его будут после того, как пролистают")
	}
	if !strings.Contains(body, "Коснётся") {
		t.Error("не сказано, кого касается выкладка")
	}
}

// Раздел берётся из другой предустановки и подставляется в форму, ничего не
// сохраняя: напечатанное в остальных разделах должно уцелеть.
func TestBorrowSectionFillsFormWithoutSaving(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	admin, _ := db.CreateAdmin(ctx, nil, "eugene", hash)
	token, _ := db.StartSession(ctx, admin.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	source, _ := db.CreatePreset(ctx, nil, "Менеджер")
	if _, err := db.SaveRevision(ctx, nil, source.ID, 1, []byte(
		`{"siteAddresses":{"office":"10.0.0.5","remote":"crm.elitesochi.com"}}`), ""); err != nil {
		t.Fatalf("SaveRevision: %v", err)
	}
	target, _ := db.CreatePreset(ctx, nil, "Стажёр")

	// В форме уже что-то напечатано — код конференции из другого раздела.
	form := url.Values{
		"section":       {"link"},
		"from_link":     {strconv.FormatInt(source.ID, 10)},
		"featureCode":   {"*77"},
		"roomExtension": {"8000"},
		"office":        {""},
		"remote":        {""},
	}
	r := s.authed(cookie, "/presets/"+strconv.FormatInt(target.ID, 10)+"/borrow", form)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)

	body := w.Body.String()
	if !strings.Contains(body, "crm.elitesochi.com") {
		t.Error("взятый раздел не подставился в форму")
	}
	if !strings.Contains(body, "*77") {
		t.Error("подстановка затёрла напечатанное в другом разделе")
	}
	if _, err := db.LatestRevision(ctx, target.ID); err == nil {
		t.Error("подстановка сохранила ревизию, хотя ничего сохранять не должна")
	}
}
