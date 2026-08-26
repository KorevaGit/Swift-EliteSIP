package web

import (
	"bytes"
	"context"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/koreva/elitesip-site/internal/panel"
	"github.com/koreva/elitesip-site/internal/storage"
)

// signedIn заводит администратора и возвращает его куку сеанса.
func signedIn(t *testing.T, db *storage.DB) *http.Cookie {
	t.Helper()
	hash, _ := panel.HashPassword("пароль-панели")
	admin, err := db.CreateAdmin(context.Background(), nil, "eugene", hash)
	if err != nil {
		t.Fatalf("CreateAdmin: %v", err)
	}
	token, err := db.StartSession(context.Background(), admin.ID)
	if err != nil {
		t.Fatalf("StartSession: %v", err)
	}
	return &http.Cookie{Name: sessionCookie, Value: token}
}

// newSandboxPost собирает форму создания так, как её шлёт браузер: multipart,
// потому что вместе с полями едет файл холодной базы.
func (s *Server) newSandboxPost(cookie *http.Cookie, fields map[string]string, dealsCSV string) *http.Request {
	var body bytes.Buffer
	form := multipart.NewWriter(&body)

	form.WriteField(csrfField, s.csrfToken(cookie.Value))
	for name, value := range fields {
		form.WriteField(name, value)
	}
	if dealsCSV != "" {
		file, _ := form.CreateFormFile("deals", "deals.csv")
		file.Write([]byte(dealsCSV))
	}
	form.Close()

	r := httptest.NewRequest(http.MethodPost, "/sandbox", &body)
	r.Header.Set("Content-Type", form.FormDataContentType())
	r.AddCookie(cookie)
	return r
}

func get(t *testing.T, s *Server, cookie *http.Cookie, path string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(http.MethodGet, path, nil)
	r.AddCookie(cookie)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)
	return w
}

// Заглушки больше нет: раздел открывается своим списком, а не страницей
// «в разработке».
func TestSandboxSectionReplacedTheStub(t *testing.T) {
	s, db := newServer(t)
	cookie := signedIn(t, db)

	body := get(t, s, cookie, "/sandbox").Body.String()
	// Пункт шапки — обычная ссылка без пометки «в разработке». Проверяем именно
	// его: у PBX такая пометка законно осталась, и искать строку по всей
	// странице значило бы ловить чужой замок.
	if !strings.Contains(body, `href="/sandbox">Песочница</a>`) {
		t.Error("пункт «Песочница» всё ещё помечен как незаконченный")
	}
	if strings.Contains(body, "Ведение стажёров по шагам") {
		t.Error("на месте раздела осталась прежняя заглушка")
	}
	if !strings.Contains(body, "Открытых песков нет") {
		t.Error("нет объяснения пустого списка")
	}
	// Подшапка раздела: «Пески», «Архив», «Шаблон».
	for _, item := range []string{`href="/sandbox/archive"`, `href="/sandbox/template"`} {
		if !strings.Contains(body, item) {
			t.Errorf("в подшапке нет %s", item)
		}
	}
}

// Главный путь раздела: песок заводится одной формой и сразу виден в списке
// со своим РОПом, форматом, числом людей и процентами по разделам.
func TestCreateSandboxShowsUpInList(t *testing.T) {
	s, db := newServer(t)
	cookie := signedIn(t, db)

	create := s.newSandboxPost(cookie, map[string]string{
		"rop":        "Кочура",
		"format":     "office",
		"employees":  "Смирнов Пётр\nИванова Анна\n\nКузнецов Игорь",
		"extensions": "301-303",
	}, "1, 2\n2516934, 10660\n2517017, 10660\n")

	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, create)
	if w.Code != http.StatusSeeOther {
		t.Fatalf("создание дало код %d: %s", w.Code, w.Body.String())
	}
	if got := w.Header().Get("Location"); got != "/sandbox" {
		t.Fatalf("после создания отправило на %q", got)
	}

	body := get(t, s, cookie, "/sandbox").Body.String()
	if !strings.Contains(body, "Песок заведён") {
		t.Error("нет сообщения о заведённом песке")
	}
	if !strings.Contains(body, "Кочура") {
		t.Fatal("песка нет в списке")
	}
	if !strings.Contains(body, ">3<") {
		t.Error("в списке не видно, что людей трое")
	}
	// Проценты по разделам, а не одно число на песок.
	for _, section := range []string{"аккаунты", "телефония", "техника", "исход"} {
		if !strings.Contains(body, section) {
			t.Errorf("в строке нет раздела %q", section)
		}
	}

	cards, err := s.Sand.ListSandboxes(context.Background(), false)
	if err != nil || len(cards) != 1 {
		t.Fatalf("в базе песков %d (%v)", len(cards), err)
	}
	if cards[0].Employees != 3 {
		t.Errorf("людей записано %d, ожидалось 3 — пустая строка формы человеком не считается", cards[0].Employees)
	}
}

// Заведённый песок виден в общем журнале без правки экрана журнала: событие
// уходит в outbox одной транзакцией и относится в основную базу сразу.
func TestCreatedSandboxReachesSharedAuditLog(t *testing.T) {
	s, db := newServer(t)
	cookie := signedIn(t, db)

	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, s.newSandboxPost(cookie, map[string]string{
		"rop": "Власов", "format": "remote", "employees": "Смирнов Пётр",
	}, ""))
	if w.Code != http.StatusSeeOther {
		t.Fatalf("создание дало код %d", w.Code)
	}

	entries, err := db.AuditPage(context.Background(), storage.AuditFilter{Action: "sandbox.create"})
	if err != nil {
		t.Fatalf("прочитать журнал: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("записей в журнале %d", len(entries))
	}
	if entries[0].ActorLogin != "eugene" {
		t.Errorf("в журнале не тот исполнитель: %q", entries[0].ActorLogin)
	}
	if !strings.Contains(entries[0].Details, "Власов") {
		t.Errorf("в журнале нет РОПа: %q", entries[0].Details)
	}
}

// Пустой песок создать нельзя, и форма при отказе возвращает набранное: в ней
// до тридцати ФИО, и терять их из-за отказа незачем.
func TestSandboxFormKeepsInputOnRefusal(t *testing.T) {
	s, db := newServer(t)
	cookie := signedIn(t, db)

	// Первый песок Кочуры заводится.
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, s.newSandboxPost(cookie, map[string]string{
		"rop": "Кочура", "format": "office", "employees": "Смирнов Пётр",
	}, ""))
	if w.Code != http.StatusSeeOther {
		t.Fatalf("первый песок: %d", w.Code)
	}

	// Второй незакрытый песок тому же РОПу — отказ человеческими словами.
	w = httptest.NewRecorder()
	s.Handler().ServeHTTP(w, s.newSandboxPost(cookie, map[string]string{
		"rop": "Кочура", "format": "office", "employees": "Иванова Анна", "extensions": "401",
	}, ""))

	body := w.Body.String()
	if w.Code != http.StatusOK {
		t.Fatalf("отказ дал код %d, ожидалась перерисованная форма", w.Code)
	}
	if !strings.Contains(body, "уже есть незакрытый песок") {
		t.Errorf("отказ объяснён не по-человечески: %s", body)
	}
	if !strings.Contains(body, "Иванова Анна") || !strings.Contains(body, "401") {
		t.Error("набранное в форме потерялось при отказе")
	}

	cards, _ := s.Sand.ListSandboxes(context.Background(), false)
	if len(cards) != 1 {
		t.Errorf("песков в базе %d", len(cards))
	}
}

// Пустой песок и чужой РОП форма не пропускает, и ничего не создаёт.
func TestSandboxFormRefusesEmptyAndUnknownROP(t *testing.T) {
	s, db := newServer(t)
	cookie := signedIn(t, db)

	cases := map[string]map[string]string{
		"без людей": {"rop": "Кочура", "format": "office", "employees": "   \n  "},
		"чужой РОП": {"rop": "Иванов", "format": "office", "employees": "Смирнов Пётр"},
		"номер не номер": {
			"rop": "Кочура", "format": "office",
			"employees": "Смирнов Пётр", "extensions": "три-ноль-один",
		},
	}
	for name, fields := range cases {
		w := httptest.NewRecorder()
		s.Handler().ServeHTTP(w, s.newSandboxPost(cookie, fields, ""))
		if w.Code != http.StatusOK {
			t.Errorf("%s: код %d, ожидалась перерисованная форма", name, w.Code)
		}
		if !strings.Contains(w.Body.String(), "notice-bad") {
			t.Errorf("%s: отказ без объяснения", name)
		}
	}

	cards, _ := s.Sand.ListSandboxes(context.Background(), false)
	if len(cards) != 0 {
		t.Errorf("после отказов в базе песков %d", len(cards))
	}
}

// Номер из пула другого незакрытого песка не принимается: это два человека на
// одном добавочном.
func TestSandboxFormRefusesBusyNumber(t *testing.T) {
	s, db := newServer(t)
	cookie := signedIn(t, db)

	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, s.newSandboxPost(cookie, map[string]string{
		"rop": "Кочура", "format": "office", "employees": "Смирнов Пётр", "extensions": "301-305",
	}, ""))
	if w.Code != http.StatusSeeOther {
		t.Fatalf("первый песок: %d", w.Code)
	}

	w = httptest.NewRecorder()
	s.Handler().ServeHTTP(w, s.newSandboxPost(cookie, map[string]string{
		"rop": "Власов", "format": "office", "employees": "Иванова Анна", "extensions": "305, 306",
	}, ""))
	if !strings.Contains(w.Body.String(), "другого незакрытого песка") {
		t.Errorf("занятый номер принят или объяснён невнятно: %d", w.Code)
	}

	cards, _ := s.Sand.ListSandboxes(context.Background(), false)
	if len(cards) != 1 {
		t.Errorf("песков в базе %d, ожидался один", len(cards))
	}
}

// Форма создания требует токен так же, как остальные: файл в ней ничего не
// меняет.
func TestSandboxCreateNeedsCSRFToken(t *testing.T) {
	s, db := newServer(t)
	cookie := signedIn(t, db)

	var body bytes.Buffer
	form := multipart.NewWriter(&body)
	form.WriteField("rop", "Кочура")
	form.WriteField("format", "office")
	form.WriteField("employees", "Смирнов Пётр")
	form.Close()

	r := httptest.NewRequest(http.MethodPost, "/sandbox", &body)
	r.Header.Set("Content-Type", form.FormDataContentType())
	r.AddCookie(cookie)

	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)
	if w.Code != http.StatusForbidden {
		t.Errorf("код %d, ожидался 403", w.Code)
	}

	cards, _ := s.Sand.ListSandboxes(context.Background(), false)
	if len(cards) != 0 {
		t.Error("песок завёлся без токена формы")
	}
}

// Архив показывает закрытые и не показывает идущие.
func TestArchiveShowsClosedOnly(t *testing.T) {
	s, db := newServer(t)
	cookie := signedIn(t, db)

	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, s.newSandboxPost(cookie, map[string]string{
		"rop": "Кочура", "format": "office", "employees": "Смирнов Пётр",
	}, ""))
	w = httptest.NewRecorder()
	s.Handler().ServeHTTP(w, s.newSandboxPost(cookie, map[string]string{
		"rop": "Марк", "format": "remote", "employees": "Иванова Анна",
	}, ""))

	if _, err := s.Sand.Exec(
		`UPDATE sandboxes SET closed_at = '2026-08-26T10:00:00Z', closed_by = 1 WHERE rop = 'Марк'`); err != nil {
		t.Fatalf("закрыть песок: %v", err)
	}

	// Сообщения о заведённых песках называют РОПов и показываются один раз на
	// следующей же странице. Снимаем их отдельным заходом, иначе проверка
	// ловила бы имя из сообщения, а не из таблицы архива.
	get(t, s, cookie, "/overview")

	archive := get(t, s, cookie, "/sandbox/archive").Body.String()
	if !strings.Contains(archive, "Марк") {
		t.Error("закрытого песка нет в архиве")
	}
	if strings.Contains(archive, "Кочура") {
		t.Error("идущий песок попал в архив")
	}

	live := get(t, s, cookie, "/sandbox").Body.String()
	if strings.Contains(live, "Марк") {
		t.Error("закрытый песок остался в списке идущих")
	}
}

// Экран шаблона показывает работы обоих уровней и подменяет формулировки для
// удалённого песка, не меняя ключей.
func TestTemplateScreenShowsBothFormats(t *testing.T) {
	s, db := newServer(t)
	cookie := signedIn(t, db)

	office := get(t, s, cookie, "/sandbox/template").Body.String()
	if !strings.Contains(office, "Выдана техника на песок") || !strings.Contains(office, "Выдан пул ключей") {
		t.Error("на экране шаблона нет офисных работ")
	}
	if !strings.Contains(office, "Создан аккаунт в Битриксе") {
		t.Error("нет работ по сотруднику")
	}

	remote := get(t, s, cookie, "/sandbox/template?format=remote").Body.String()
	if strings.Contains(remote, "Выдана техника на песок") {
		t.Error("удалёнщикам показана выдача техники")
	}
	if !strings.Contains(remote, "Настроен удалённый доступ") {
		t.Error("нет удалённой настройки вместо выдачи техники")
	}
	// Ключ остаётся прежним в обоих форматах — на нём держатся отметки.
	if !strings.Contains(remote, "hardware") || !strings.Contains(office, "hardware") {
		t.Error("ключ работы не показан или разъехался между форматами")
	}
}

// Техподдержка ведёт пески наравне с администратором: закрытие — единственное,
// что за администратором, и оно приходит в шестом этапе.
func TestSupportCanRunSandboxes(t *testing.T) {
	s, db := newServer(t)
	ctx := context.Background()

	hash, _ := panel.HashPassword("пароль-панели")
	person, err := db.CreateAdminWithRole(ctx, nil, "olga", hash, "support")
	if err != nil {
		t.Fatalf("CreateAdminWithRole: %v", err)
	}
	token, _ := db.StartSession(ctx, person.ID)
	cookie := &http.Cookie{Name: sessionCookie, Value: token}

	for _, path := range []string{"/sandbox", "/sandbox/archive", "/sandbox/new", "/sandbox/template"} {
		if code := get(t, s, cookie, path).Code; code != http.StatusOK {
			t.Errorf("%s закрыт для техподдержки: %d", path, code)
		}
	}

	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, s.newSandboxPost(cookie, map[string]string{
		"rop": "Скрылева", "format": "office", "employees": "Смирнов Пётр",
	}, ""))
	if w.Code != http.StatusSeeOther {
		t.Fatalf("техподдержка не смогла завести песок: %d", w.Code)
	}

	cards, _ := s.Sand.ListSandboxes(ctx, false)
	if len(cards) != 1 {
		t.Errorf("песков заведено %d", len(cards))
	}
}

// Форма создания отдаёт справочник РОПов списком, а не полем свободного ввода.
func TestNewSandboxFormOffersROPDirectory(t *testing.T) {
	s, db := newServer(t)
	cookie := signedIn(t, db)

	body := get(t, s, cookie, "/sandbox/new").Body.String()
	for _, rop := range []string{"Сайдаралиев", "Кочура", "Власов", "Макаренко", "Шахалиева", "Марк", "Скрылева"} {
		if !strings.Contains(body, ">"+rop+"<") {
			t.Errorf("в справочнике формы нет %q", rop)
		}
	}
	if !strings.Contains(body, `name="csrf"`) {
		t.Error("в форме нет токена")
	}
	if !strings.Contains(body, `enctype="multipart/form-data"`) {
		t.Error("форма не умеет принять файл сделок")
	}
}

// Счётчик песочницы виден на общем обзоре: пометки «в разработке» там больше
// нет, а плитка обязана говорить правду.
func TestOverviewCountsSandboxes(t *testing.T) {
	s, db := newServer(t)
	cookie := signedIn(t, db)

	body := get(t, s, cookie, "/overview").Body.String()
	if !strings.Contains(body, "открытых песков нет") {
		t.Error("на обзоре не сказано, что песков нет")
	}

	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, s.newSandboxPost(cookie, map[string]string{
		"rop": "Кочура", "format": "office", "employees": "Смирнов Пётр",
	}, ""))
	if w.Code != http.StatusSeeOther {
		t.Fatalf("создание: %d", w.Code)
	}

	body = get(t, s, cookie, "/overview").Body.String()
	if !strings.Contains(body, "1 песок идёт") {
		t.Error("счётчик песков на обзоре не обновился")
	}
}

// Форма без файла — обычный случай: базу наливают не в первый день, и
// требовать выгрузку при заведении песка значило бы держать группу без карточек.
func TestSandboxCreatesWithoutDealsFile(t *testing.T) {
	s, db := newServer(t)
	cookie := signedIn(t, db)

	// Та же форма, но отправленная без multipart вовсе.
	values := url.Values{
		"rop": {"Макаренко"}, "format": {"office"}, "employees": {"Смирнов Пётр"},
	}
	r := s.authed(cookie, "/sandbox", values)
	w := httptest.NewRecorder()
	s.Handler().ServeHTTP(w, r)

	if w.Code != http.StatusSeeOther {
		t.Fatalf("код %d: %s", w.Code, w.Body.String())
	}
	cards, _ := s.Sand.ListSandboxes(context.Background(), false)
	if len(cards) != 1 {
		t.Fatalf("песков заведено %d", len(cards))
	}
}
